#ifndef MEMORABLE_SENTENCEPIECE_NATIVE_H
#define MEMORABLE_SENTENCEPIECE_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MemorableSentencePiece MemorableSentencePiece;

// Every failure returns NULL/-1 and a NUL-terminated diagnostic in error.
MemorableSentencePiece *memorable_sp_create(const void *model, size_t model_size,
                                           char *error, size_t error_capacity);
void memorable_sp_destroy(MemorableSentencePiece *processor);
int32_t memorable_sp_eos_id(const MemorableSentencePiece *processor);
int32_t memorable_sp_pad_id(const MemorableSentencePiece *processor);

// Returns the number of IDs copied, bounded by capacity. Truncation is deliberate:
// the caller reserves one model context slot for EOS. Input is length-delimited
// UTF-8, including any embedded NUL. No C++ objects/exceptions cross this ABI.
int32_t memorable_sp_encode(const MemorableSentencePiece *processor,
                            const char *text, size_t text_size,
                            int32_t *tokens, int32_t capacity,
                            char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
