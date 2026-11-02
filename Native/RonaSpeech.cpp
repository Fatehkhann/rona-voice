#include "RonaSpeech.h"
#include <onnxruntime_cxx_api.h>
#include <sentencepiece_processor.h>
#include <nlohmann/json.hpp>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <random>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <vector>

using json = nlohmann::json;
namespace {
// Model generation constants from the supplied pocket_onnx.py reference.
constexpr float temperature = 0.3f, eosThreshold = -4.0f;
constexpr int minimumFramesBeforeEOS = 6, maxTokensPerChunk = 50;
constexpr double tokensPerSecond = 3.0, generationPaddingSeconds = 2.0;
// First output after 400 ms of generated speech; subsequent buffers hold 1.2 s.
constexpr int initialDecodeFrames = 5, steadyDecodeFrames = 15;
using State = std::vector<Ort::Value>;

json readJSON(const std::string &path) {
    std::ifstream file(path);
    if (!file) throw std::runtime_error("Missing model resource: " + path);
    return json::parse(file);
}

template<class T> Ort::Value tensor(const std::vector<int64_t> &shape, T fill = T{}) {
    Ort::AllocatorWithDefaultOptions allocator;
    auto result = Ort::Value::CreateTensor<T>(allocator, shape.data(), shape.size());
    auto count = result.GetTensorTypeAndShapeInfo().GetElementCount();
    std::fill_n(result.template GetTensorMutableData<T>(), count, fill);
    return result;
}

Ort::Value floats(const std::vector<int64_t> &shape, const std::vector<float> &data) {
    auto result = tensor<float>(shape);
    if (result.GetTensorTypeAndShapeInfo().GetElementCount() != data.size())
        throw std::runtime_error("Invalid model tensor dimensions.");
    std::copy(data.begin(), data.end(), result.GetTensorMutableData<float>());
    return result;
}

std::vector<float> readFloats(const std::string &path, bool numpy = false) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Missing voice resource: " + path);
    auto length = static_cast<size_t>(file.tellg());
    file.seekg(0);
    size_t offset = 0;
    if (numpy) {
        unsigned char header[12]{};
        file.read(reinterpret_cast<char *>(header), 10);
        if (std::memcmp(header, "\x93NUMPY", 6) != 0 || header[6] != 1)
            throw std::runtime_error("Unsupported BOS numpy format.");
        offset = 10 + header[8] + 256 * header[9];
        file.seekg(offset);
    }
    if (length < offset || (length - offset) % sizeof(float))
        throw std::runtime_error("Invalid voice embedding size.");
    std::vector<float> result((length - offset) / sizeof(float));
    file.read(reinterpret_cast<char *>(result.data()), result.size() * sizeof(float));
    if (!file) throw std::runtime_error("Unable to read voice embeddings.");
    return result;
}

struct Graph {
    Ort::Session session;
    std::vector<std::string> outputs;
    Graph(Ort::Env &environment, const std::string &path, Ort::SessionOptions &options)
        : session(environment, path.c_str(), options) {
        Ort::AllocatorWithDefaultOptions allocator;
        for (size_t i = 0; i < session.GetOutputCount(); ++i)
            outputs.emplace_back(session.GetOutputNameAllocated(i, allocator).get());
    }
    State run(std::vector<const char *> names, State inputs, State *state = nullptr,
              const json *manifest = nullptr, int offset = 0) {
        if (state) {
            for (size_t i = 0; i < state->size(); ++i) {
                names.push_back((*manifest)[i]["input_name"].get_ref<const std::string &>().c_str());
                inputs.push_back(std::move((*state)[i]));
            }
        }
        std::vector<const char *> outputNames;
        for (const auto &name : outputs) outputNames.push_back(name.c_str());
        auto result = session.Run(Ort::RunOptions{nullptr}, names.data(), inputs.data(), inputs.size(),
                                  outputNames.data(), outputNames.size());
        if (state) {
            state->clear();
            for (const auto &entry : *manifest) {
                size_t index = offset + entry["index"].get<size_t>();
                state->push_back(std::move(result.at(index)));
            }
            result.erase(result.begin() + offset, result.end());
        }
        return result;
    }
};

std::string prepare(std::string text) {
    for (const auto &quote : {std::string("’"), std::string("‘")}) {
        size_t position = 0;
        while ((position = text.find(quote, position)) != std::string::npos) text.replace(position, quote.size(), "'");
    }
    std::istringstream words(text);
    std::string word;
    text.clear();
    while (words >> word) { if (!text.empty()) text += " "; text += word; }
    if (text.empty()) throw std::runtime_error("There is no text to speak.");
    text = std::regex_replace(text, std::regex("([.!?])\\s*[,;:]"), "$1");
    if (static_cast<unsigned char>(text.front()) < 128)
        text.front() = std::toupper(static_cast<unsigned char>(text.front()));
    const auto core = text.find_last_not_of("\"' )]");
    if (core != std::string::npos && std::string(".!?").find(text[core]) == std::string::npos) {
        if (std::string(",;:-").find(text[core]) != std::string::npos) text[core] = '.';
        else text.insert(core + 1, ".");
    }
    return text;
}

void reportError(char **output, const std::exception &error) {
    if (output) *output = strdup(error.what());
}
}

struct YVCancellation { std::atomic<bool> cancelled{false}; };

struct YVEngine {
    std::string directory;
    json metadata, flowManifest, decoderManifest, voiceManifest;
    int conditioningDimension, latentDimension, sampleRate;
    double frameRate;
    Ort::Env environment{ORT_LOGGING_LEVEL_ERROR, "RonaVoice"};
    Ort::SessionOptions options;
    std::unique_ptr<Graph> text, main, flow, decoder;
    sentencepiece::SentencePieceProcessor tokenizer;
    std::vector<float> bos;
    std::map<std::string, State> voices;

    explicit YVEngine(const std::string &path) : directory(path) {
        metadata = readJSON(path + "/bundle.json");
        flowManifest = metadata["flow_lm_state_manifest"];
        decoderManifest = metadata["mimi_state_manifest"];
        voiceManifest = readJSON(path + "/voices/voices.json")["voices"];
        conditioningDimension = metadata["conditioning_dim"];
        latentDimension = metadata["latent_dim"];
        sampleRate = metadata["sample_rate"];
        frameRate = metadata["frame_rate"];
        if (sampleRate != 24000 || conditioningDimension != 1024 || latentDimension != 32)
            throw std::runtime_error("This voice bundle uses an unsupported model configuration.");
        const auto status = tokenizer.Load(path + "/" + metadata["tokenizer_file"].get<std::string>());
        if (!status.ok()) throw std::runtime_error(status.ToString());
        bos = readFloats(path + "/" + metadata["bos_before_voice_file"].get<std::string>(), true);
        if (bos.size() != static_cast<size_t>(conditioningDimension))
            throw std::runtime_error("Invalid BOS embedding.");
        options.SetIntraOpNumThreads(4);
        options.SetInterOpNumThreads(1);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        // Allow idle worker threads to sleep between turns rather than spinning.
        options.AddConfigEntry("session.intra_op.allow_spinning", "0");
        text = std::make_unique<Graph>(environment, path + "/text_conditioner.onnx", options);
        main = std::make_unique<Graph>(environment, path + "/flow_lm_main.onnx", options);
        flow = std::make_unique<Graph>(environment, path + "/flow_lm_flow.onnx", options);
        decoder = std::make_unique<Graph>(environment, path + "/mimi_decoder.onnx", options);
    }

    State initialize(const json &manifest, int cacheLength = 0) {
        State state;
        for (const auto &entry : manifest) {
            auto shape = entry["shape"].get<std::vector<int64_t>>();
            if (cacheLength && entry["key"] == "cache") shape[2] = cacheLength;
            if (entry["dtype"] == "float32") {
                float fill = entry["fill"] == "nan" ? std::numeric_limits<float>::quiet_NaN() : 0;
                state.push_back(tensor<float>(shape, fill));
            } else if (entry["dtype"] == "int64") state.push_back(tensor<int64_t>(shape));
            else if (entry["dtype"] == "bool") state.push_back(tensor<bool>(shape, entry["fill"] == "ones"));
            else throw std::runtime_error("Unsupported state tensor type.");
        }
        return state;
    }

    State runMain(State &state, Ort::Value sequence, Ort::Value embeddings) {
        State inputs;
        inputs.push_back(std::move(sequence)); inputs.push_back(std::move(embeddings));
        return main->run({"sequence", "text_embeddings"}, std::move(inputs), &state, &flowManifest, 2);
    }

    const State &voice(const std::string &name) {
        if (!voiceManifest.contains(name)) throw std::runtime_error("Unknown voice.");
        auto found = voices.find(name);
        if (found != voices.end()) return found->second;
        auto embeddings = readFloats(directory + "/voices/" + name + ".f32");
        const auto dimensions = voiceManifest[name]["shape"].get<std::vector<int>>();
        if (dimensions.size() != 2 || dimensions[1] != conditioningDimension ||
            embeddings.size() != static_cast<size_t>(dimensions[0] * dimensions[1]))
            throw std::runtime_error("Invalid voice prompt dimensions.");
        embeddings.insert(embeddings.begin(), bos.begin(), bos.end());
        int count = static_cast<int>(embeddings.size()) / conditioningDimension;
        auto state = initialize(flowManifest, count);
        runMain(state, tensor<float>({1, 0, latentDimension}), floats({1, count, conditioningDimension}, embeddings));
        return voices.emplace(name, std::move(state)).first->second;
    }

    State expand(const State &source, int slots) {
        State state;
        for (size_t i = 0; i < source.size(); ++i) {
            auto info = source[i].GetTensorTypeAndShapeInfo();
            auto shape = info.GetShape();
            if (flowManifest[i]["key"] == "cache") {
                auto oldSlots = shape[2];
                shape[2] = std::max<int64_t>(oldSlots, slots);
                auto copy = tensor<float>(shape, std::numeric_limits<float>::quiet_NaN());
                const auto stride = shape[3] * shape[4];
                for (int64_t row = 0; row < shape[0] * shape[1]; ++row)
                    std::copy_n(source[i].GetTensorData<float>() + row * oldSlots * stride, oldSlots * stride,
                                copy.GetTensorMutableData<float>() + row * shape[2] * stride);
                state.push_back(std::move(copy));
            } else if (info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
                auto copy = tensor<int64_t>(shape);
                std::copy_n(source[i].GetTensorData<int64_t>(), info.GetElementCount(), copy.GetTensorMutableData<int64_t>());
                state.push_back(std::move(copy));
            } else {
                auto copy = tensor<float>(shape);
                std::copy_n(source[i].GetTensorData<float>(), info.GetElementCount(), copy.GetTensorMutableData<float>());
                state.push_back(std::move(copy));
            }
        }
        return state;
    }

    std::vector<int> tokens(const std::string &value) const {
        std::vector<int> result;
        auto status = tokenizer.Encode(value, &result);
        if (!status.ok()) throw std::runtime_error(status.ToString());
        return result;
    }

    std::vector<std::string> chunks(const std::string &value) const {
        auto ids = tokens(prepare(value));
        auto terminalTokens = tokens(".!...?");
        std::set<int> terminal(terminalTokens.begin() + 1, terminalTokens.end());
        std::vector<std::string> result;
        size_t begin = 0;
        while (begin < ids.size()) {
            size_t limit = std::min(begin + maxTokensPerChunk, ids.size());
            size_t end = limit;
            // Prefer sentence boundaries, preserving decimal periods (e.g. 3.14).
            for (size_t i = begin + 1; i < limit; ++i) {
                if (!terminal.count(ids[i])) continue;
                auto previous = tokenizer.IdToPiece(ids[i - 1]);
                auto next = i + 1 < ids.size() ? tokenizer.IdToPiece(ids[i + 1]) : "";
                bool decimal = tokenizer.IdToPiece(ids[i]) == "." && !previous.empty() && !next.empty()
                    && std::isdigit(static_cast<unsigned char>(previous.back()))
                    && std::isdigit(static_cast<unsigned char>(next.front()));
                if (!decimal) end = i + 1;
            }
            if (end == limit && limit < ids.size()) {
                // Hard bound long, unpunctuated responses without splitting a word when possible.
                for (size_t i = limit; i > begin + 1; --i) {
                    if (tokenizer.IdToPiece(ids[i]).rfind("▁", 0) == 0) { end = i; break; }
                }
            }
            std::string chunk;
            auto status = tokenizer.Decode(std::vector<int>(ids.begin() + begin, ids.begin() + end), &chunk);
            if (!status.ok()) throw std::runtime_error(status.ToString());
            if (chunk.find_first_not_of(" \n\t") != std::string::npos) result.push_back(chunk);
            begin = end;
        }
        return result;
    }

    void synthesize(const std::string &value, const std::string &voiceName, YVCancellation &cancel,
                    YVAudioCallback callback, void *context) {
        if (value.size() > 16384) throw std::runtime_error("Text is too long for a single voice request.");
        if (cancel.cancelled) return;
        const auto &voiceState = voice(voiceName);
        std::mt19937 random(std::random_device{}());
        std::normal_distribution<float> noise(0, std::sqrt(temperature));
        for (const auto &chunk : chunks(value)) {
            if (cancel.cancelled) return;
            auto prepared = prepare(chunk);
            int words = 1 + static_cast<int>(std::count(prepared.begin(), prepared.end(), ' '));
            int framesAfterEOS = (words <= 4 ? 3 : 1) + 2;
            auto ids = tokens(prepared);
            int maxFrames = static_cast<int>(std::ceil((ids.size() / tokensPerSecond + generationPaddingSeconds) * frameRate));
            int voiceLength = static_cast<int>(voiceState.front().GetTensorTypeAndShapeInfo().GetShape()[2]);
            auto state = expand(voiceState, voiceLength + static_cast<int>(ids.size()) + maxFrames + 1);
            auto tokenTensor = tensor<int64_t>({1, static_cast<int64_t>(ids.size())});
            std::copy(ids.begin(), ids.end(), tokenTensor.GetTensorMutableData<int64_t>());
            State textInputs;
            textInputs.push_back(std::move(tokenTensor));
            auto embeddings = text->run({"token_ids"}, std::move(textInputs));
            runMain(state, tensor<float>({1, 0, latentDimension}), std::move(embeddings[0]));
            auto latent = tensor<float>({1, 1, latentDimension}, std::numeric_limits<float>::quiet_NaN());
            auto decoderState = initialize(decoderManifest);
            std::vector<float> pending;
            int eosStep = -1;
            bool firstBuffer = true;
            auto decode = [&] {
                if (pending.empty() || cancel.cancelled) return;
                State inputs;
                inputs.push_back(floats({1, static_cast<int64_t>(pending.size() / latentDimension), latentDimension}, pending));
                auto decoded = decoder->run({"latent"}, std::move(inputs), &decoderState, &decoderManifest, 1);
                auto count = decoded[0].GetTensorTypeAndShapeInfo().GetElementCount();
                auto samples = decoded[0].GetTensorMutableData<float>();
                size_t fade = std::min(count, static_cast<size_t>(sampleRate / 200)); // reference 5 ms fade-in
                for (size_t i = 0; i < count; ++i) {
                    if (!std::isfinite(samples[i])) throw std::runtime_error("Voice model produced invalid audio.");
                    samples[i] = std::clamp(samples[i], -1.0f, 1.0f);
                    if (firstBuffer && i < fade) samples[i] *= static_cast<float>(i) / std::max<size_t>(fade - 1, 1);
                }
                if (!cancel.cancelled) callback(samples, count, context);
                firstBuffer = false;
                pending.clear();
            };
            for (int step = 0; step < maxFrames; ++step) {
                if (cancel.cancelled) return;
                auto output = runMain(state, std::move(latent), tensor<float>({1, 0, conditioningDimension}));
                float eos = output[1].GetTensorData<float>()[0];
                if (eos > eosThreshold && eosStep < 0 && step >= minimumFramesBeforeEOS) eosStep = step;
                if (eosStep >= 0 && step >= eosStep + framesAfterEOS) break;
                std::vector<float> x(latentDimension);
                for (auto &v : x) v = noise(random);
                State flowInputs;
                flowInputs.push_back(std::move(output[0]));
                flowInputs.push_back(tensor<float>({1, 1}, 0));
                flowInputs.push_back(tensor<float>({1, 1}, 1));
                flowInputs.push_back(floats({1, latentDimension}, x));
                auto velocity = flow->run({"c", "s", "t", "x"}, std::move(flowInputs));
                auto delta = velocity[0].GetTensorData<float>();
                for (int i = 0; i < latentDimension; ++i) x[i] += delta[i];
                latent = floats({1, 1, latentDimension}, x);
                pending.insert(pending.end(), x.begin(), x.end());
                int batch = firstBuffer ? initialDecodeFrames : steadyDecodeFrames;
                if (pending.size() / latentDimension >= static_cast<size_t>(batch)) decode();
            }
            decode();
        }
    }
};

YVEngine *yv_engine_create(const char *path, char **error) {
    try { return new YVEngine(path); } catch (const std::exception &e) { reportError(error, e); return nullptr; }
}
void yv_engine_destroy(YVEngine *engine) { delete engine; }
YVCancellation *yv_cancellation_create() { return new YVCancellation; }
void yv_cancellation_cancel(YVCancellation *token) { if (token) token->cancelled = true; }
void yv_cancellation_destroy(YVCancellation *token) { delete token; }
bool yv_synthesize(YVEngine *engine, const char *text, const char *voice, YVCancellation *token,
                   YVAudioCallback callback, void *context, char **error) {
    try {
        if (!engine || !token || !callback) throw std::runtime_error("Invalid voice engine request.");
        engine->synthesize(text, voice, *token, callback, context);
        return true;
    } catch (const std::exception &e) { reportError(error, e); return false; }
}
bool yv_validate_tokenizer(YVEngine *engine, char **error) {
    try {
        auto checks = readJSON(engine->directory + "/tokenizer_check.json");
        for (auto it = checks.begin(); it != checks.end(); ++it)
            if (engine->tokens(it.key()) != it.value().get<std::vector<int>>())
                throw std::runtime_error("Tokenizer parity failed: " + it.key());
        return true;
    } catch (const std::exception &e) { reportError(error, e); return false; }
}
void yv_free_error(char *error) { free(error); }
