// webp_shim.c — libwebp static inline 函数的 C 包装（见 webp_shim.h）
#include "webp_shim.h"

int shim_WebPConfigInit(WebPConfig* config, int lossless, float quality, int method) {
    if (!WebPConfigInit(config)) return 0;
    if (lossless) {
        config->lossless = 1;
        config->quality = 75; // effort：官方推荐值（越高质量越好、越慢）
    } else {
        config->quality = quality;
        config->method = method;
    }
    return 1;
}

int shim_WebPPictureInit(WebPPicture* pic) { return WebPPictureInit(pic); }
void shim_WebPPictureFree(WebPPicture* pic) { WebPPictureFree(pic); }
void shim_WebPMemoryWriterInit(WebPMemoryWriter* writer) { WebPMemoryWriterInit(writer); }
void shim_WebPMemoryWriterClear(WebPMemoryWriter* writer) { WebPMemoryWriterClear(writer); }
