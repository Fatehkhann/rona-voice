#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct YVEngine YVEngine;
typedef struct YVCancellation YVCancellation;
// Samples are mono float32 at 24 kHz. The pointer is valid only during this call.
typedef void (*YVAudioCallback)(const float *samples, size_t count, void *context);
YVEngine *yv_engine_create(const char *bundle_path, char **error);
void yv_engine_destroy(YVEngine *engine);
YVCancellation *yv_cancellation_create(void);
void yv_cancellation_cancel(YVCancellation *token);
void yv_cancellation_destroy(YVCancellation *token);
// An engine is serial-use. Cancellation tokens may be cancelled from any thread.
bool yv_synthesize(YVEngine *engine, const char *text, const char *voice,
                   YVCancellation *token, YVAudioCallback callback, void *context, char **error);
bool yv_validate_tokenizer(YVEngine *engine, char **error);
void yv_free_error(char *error);

#ifdef __cplusplus
}
#endif
