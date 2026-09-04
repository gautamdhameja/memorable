#include "SentencePieceNative.h"

#include <algorithm>
#include <cstdio>
#include <exception>
#include <memory>
#include <string>
#include <vector>

#include "sentencepiece_processor.h"

struct MemorableSentencePiece {
  sentencepiece::SentencePieceProcessor processor;
};

namespace {
void report_error(const char *message, char *error, size_t capacity) {
  if (error && capacity) std::snprintf(error, capacity, "%s", message);
}
}  // namespace

MemorableSentencePiece *memorable_sp_create(const void *model, size_t model_size,
                                           char *error, size_t error_capacity) {
  try {
    if (!model || !model_size) {
      report_error("The tokenizer model is empty.", error, error_capacity);
      return nullptr;
    }
    auto result = std::make_unique<MemorableSentencePiece>();
    const auto status = result->processor.LoadFromSerializedProto(
        std::string_view(static_cast<const char *>(model), model_size));
    if (!status.ok()) {
      report_error(status.ToString().c_str(), error, error_capacity);
      return nullptr;
    }
    if (result->processor.eos_id() < 0 || result->processor.pad_id() < 0) {
      report_error("The tokenizer model requires EOS and padding tokens.",
                   error, error_capacity);
      return nullptr;
    }
    return result.release();
  } catch (const std::exception &exception) {
    report_error(exception.what(), error, error_capacity);
  } catch (...) {
    report_error("SentencePiece could not load the tokenizer model.", error,
                 error_capacity);
  }
  return nullptr;
}

void memorable_sp_destroy(MemorableSentencePiece *processor) { delete processor; }

int32_t memorable_sp_eos_id(const MemorableSentencePiece *processor) {
  return processor->processor.eos_id();
}

int32_t memorable_sp_pad_id(const MemorableSentencePiece *processor) {
  return processor->processor.pad_id();
}

int32_t memorable_sp_encode(const MemorableSentencePiece *processor,
                            const char *text, size_t text_size,
                            int32_t *tokens, int32_t capacity,
                            char *error, size_t error_capacity) {
  try {
    if (!processor || !text || capacity < 0 || (capacity && !tokens)) {
      report_error("Invalid tokenizer input or output buffer.", error, error_capacity);
      return -1;
    }
    std::vector<int> ids;
    const auto status = processor->processor.Encode(std::string_view(text, text_size), &ids);
    if (!status.ok()) {
      report_error(status.ToString().c_str(), error, error_capacity);
      return -1;
    }
    const auto count = std::min(ids.size(), static_cast<size_t>(capacity));
    if (count) std::copy_n(ids.begin(), count, tokens);
    return static_cast<int32_t>(count);
  } catch (const std::exception &exception) {
    report_error(exception.what(), error, error_capacity);
  } catch (...) {
    report_error("SentencePiece could not encode the query.", error, error_capacity);
  }
  return -1;
}
