// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once

#include <memory>

#include "core/framework/provider_options.h"
#include "core/providers/providers.h"

namespace onnxruntime {
struct SessionOptions;

struct WebGpuProviderFactoryCreator {
  static std::shared_ptr<IExecutionProviderFactory> Create(const SessionOptions* session_options);
};

}  // namespace onnxruntime
