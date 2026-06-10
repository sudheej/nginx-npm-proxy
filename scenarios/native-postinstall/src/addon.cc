#include <napi.h>

Napi::Value Add(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();

  if (info.Length() != 2 || !info[0].IsNumber() || !info[1].IsNumber()) {
    Napi::TypeError::New(env, "add expects two numbers")
        .ThrowAsJavaScriptException();
    return env.Null();
  }

  const double result =
      info[0].As<Napi::Number>().DoubleValue() +
      info[1].As<Napi::Number>().DoubleValue();
  return Napi::Number::New(env, result);
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set("add", Napi::Function::New(env, Add));
  return exports;
}

NODE_API_MODULE(cache_lab_addon, Init)
