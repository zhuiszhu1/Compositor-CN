// webp_shim.h — libwebp static inline 函数的 C 包装
// Swift 看不见 C 头文件里的 static WEBP_INLINE 函数，这里给非 inline 包装。
#ifndef WEBP_SHIM_H
#define WEBP_SHIM_H

#include "libwebp-src/src/webp/encode.h"

// lossless 非 0 时 quality 参数被忽略（固定 effort 75，官方推荐）。
int shim_WebPConfigInit(WebPConfig* config, int lossless, float quality, int method);
int shim_WebPPictureInit(WebPPicture* pic);
void shim_WebPPictureFree(WebPPicture* pic);
void shim_WebPMemoryWriterInit(WebPMemoryWriter* writer);
void shim_WebPMemoryWriterClear(WebPMemoryWriter* writer);

#endif
