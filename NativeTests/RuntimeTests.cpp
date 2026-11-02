#include "RonaSpeech.h"
#include <cassert>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <vector>

struct Capture {
    std::vector<float> samples;
    YVCancellation *cancel = nullptr;
    int chunks = 0;
};
void receive(const float *samples, size_t count, void *context) {
    auto &capture = *static_cast<Capture *>(context);
    for (size_t i = 0; i < count; ++i) assert(std::isfinite(samples[i]) && std::abs(samples[i]) <= 1);
    capture.samples.insert(capture.samples.end(), samples, samples + count);
    ++capture.chunks;
    if (capture.cancel) yv_cancellation_cancel(capture.cancel);
}
void wave(const std::string &path, const std::vector<float> &samples) {
    std::ofstream file(path, std::ios::binary);
    auto u16 = [&](uint16_t v) { file.write(reinterpret_cast<char *>(&v), 2); };
    auto u32 = [&](uint32_t v) { file.write(reinterpret_cast<char *>(&v), 4); };
    file.write("RIFF", 4); u32(36 + samples.size() * 2); file.write("WAVEfmt ", 8);
    u32(16); u16(1); u16(1); u32(24000); u32(48000); u16(2); u16(16);
    file.write("data", 4); u32(samples.size() * 2);
    for (float sample : samples) u16(static_cast<int16_t>(sample * 32767));
}
int main(int argc, char **argv) {
    assert(argc >= 2);
    char *error = nullptr;
    auto engine = yv_engine_create(argv[1], &error);
    if (!engine) { std::cerr << error << '\n'; return 1; }
    assert(yv_validate_tokenizer(engine, &error));
    std::cout << "PASS: all 10 reference tokenizer vectors\n";
    for (const char *voice : {"f_us_warm", "f_us_bright", "m_us_relaxed", "m_us_upbeat"}) {
        auto token = yv_cancellation_create();
        Capture capture;
        auto start = std::chrono::steady_clock::now();
        bool ok = yv_synthesize(engine, "Hello! I'm Rona. What would you like to talk about?", voice, token, receive, &capture, &error);
        if (!ok) { std::cerr << error << '\n'; return 1; }
        assert(capture.samples.size() > 24000 && capture.chunks > 1);
        double rms = 0;
        for (float sample : capture.samples) rms += sample * sample;
        assert(std::sqrt(rms / capture.samples.size()) > 0.001);
        double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        std::cout << "PASS: " << voice << ", " << capture.samples.size() / 24000.0 << " s audio, " << elapsed << " s generation\n";
        wave(std::string(".build/") + voice + ".wav", capture.samples);
        yv_cancellation_destroy(token);
    }
    auto expressiveToken = yv_cancellation_create();
    Capture expressive;
    assert(yv_synthesize(engine, "Hmm, I guess that could work. Aha! We could keep it simple. Haha, okay, now you've got me curious.",
                         "f_us_warm", expressiveToken, receive, &expressive, &error));
    assert(expressive.samples.size() > 48000);
    wave(".build/conversational-sample.wav", expressive.samples);
    yv_cancellation_destroy(expressiveToken);
    std::cout << "PASS: conversational interjections and laughter-text sample\n";
    auto token = yv_cancellation_create();
    Capture cancelled;
    cancelled.cancel = token;
    assert(yv_synthesize(engine, "This is a long response that should stop after the first audio buffer. You should never hear the rest of this sentence.", "f_us_warm", token, receive, &cancelled, &error));
    assert(cancelled.chunks == 1);
    yv_cancellation_destroy(token);
    token = yv_cancellation_create();
    yv_cancellation_cancel(token);
    Capture beforeStart;
    assert(yv_synthesize(engine, "This must not run.", "f_us_warm", token, receive, &beforeStart, &error));
    assert(beforeStart.samples.empty());
    yv_cancellation_destroy(token);
    token = yv_cancellation_create();
    Capture invalid;
    assert(!yv_synthesize(engine, "Hello", "unknown", token, receive, &invalid, &error));
    yv_free_error(error); error = nullptr;
    assert(!yv_synthesize(engine, "   ", "f_us_warm", token, receive, &invalid, &error));
    yv_free_error(error);
    yv_cancellation_destroy(token);
    yv_engine_destroy(engine);
    std::cout << "PASS: mid-stream/pre-start cancellation, invalid voice, and empty input\n";
}
