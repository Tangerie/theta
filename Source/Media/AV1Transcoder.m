#import "Include/AV1Transcoder.h"
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

// Include ffmpeg headers for type definitions and function declarations
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libavutil/imgutils.h>
#import <libavutil/opt.h>
#import <libswscale/swscale.h>

// Function pointers for ffmpeg functions (loaded dynamically via dlopen)
static void *libavcodec_handle = NULL;
static void *libavformat_handle = NULL;
static void *libavutil_handle = NULL;
static void *libswscale_handle = NULL;

// Define function pointer types
#define FUNC_PTR(name) static typeof(name) *p_##name = NULL

// avformat functions
FUNC_PTR(avformat_open_input);
FUNC_PTR(avformat_find_stream_info);
FUNC_PTR(avformat_close_input);
FUNC_PTR(avformat_alloc_output_context2);
FUNC_PTR(avformat_new_stream);
FUNC_PTR(avformat_write_header);
FUNC_PTR(avformat_free_context);
FUNC_PTR(av_read_frame);
FUNC_PTR(av_interleaved_write_frame);
FUNC_PTR(av_write_trailer);
FUNC_PTR(avio_open);
FUNC_PTR(avio_closep);
FUNC_PTR(av_guess_frame_rate);

// avcodec functions
FUNC_PTR(avcodec_find_decoder);
FUNC_PTR(avcodec_find_encoder);
FUNC_PTR(avcodec_find_encoder_by_name);
FUNC_PTR(avcodec_alloc_context3);
FUNC_PTR(avcodec_free_context);
FUNC_PTR(avcodec_parameters_to_context);
FUNC_PTR(avcodec_parameters_from_context);
FUNC_PTR(avcodec_parameters_copy);
FUNC_PTR(avcodec_open2);
FUNC_PTR(avcodec_send_packet);
FUNC_PTR(avcodec_receive_frame);
FUNC_PTR(avcodec_send_frame);
FUNC_PTR(avcodec_receive_packet);
FUNC_PTR(avcodec_get_name);

// avutil functions
FUNC_PTR(av_frame_alloc);
FUNC_PTR(av_frame_free);
FUNC_PTR(av_frame_get_buffer);
FUNC_PTR(av_frame_unref);
FUNC_PTR(av_packet_alloc);
FUNC_PTR(av_packet_free);
FUNC_PTR(av_packet_unref);
FUNC_PTR(av_packet_rescale_ts);
FUNC_PTR(av_opt_set);
FUNC_PTR(av_opt_set_int);
FUNC_PTR(av_strerror);

// swscale functions
FUNC_PTR(sws_getContext);
FUNC_PTR(sws_scale);
FUNC_PTR(sws_freeContext);

#define LOAD_FUNC(handle, name) \
    p_##name = dlsym(handle, #name); \
    if (!p_##name) { \
        NSLog(@"Failed to load function %s: %s", #name, dlerror()); \
        return NO; \
    }

static BOOL ffmpegLibrariesLoaded = NO;

static BOOL loadFFmpegLibraries(NSError **error) {
    if (ffmpegLibrariesLoaded) {
        return YES;
    }
    
    // Determine base path based on build configuration
    NSString *basePath;
    #if defined(SIDELOAD)
        // For sideloaded builds, ffmpeg is in the root app directory (same level as Instagram executable)
        basePath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"ffmpeg.framework"];
    #else
        // Jailbroken: try bundle first (in case framework was embedded), then rootless, then rootful
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bundlePath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"ffmpeg.framework"];
        NSString *rootlessPath = @"/var/jb/Library/Application Support/ffmpeg.framework";
        NSString *rootfulPath = @"/Library/Application Support/ffmpeg.framework";
        
        if ([fm fileExistsAtPath:bundlePath]) {
            basePath = bundlePath;
        } else if ([fm fileExistsAtPath:rootlessPath]) {
            basePath = rootlessPath;
        } else if ([fm fileExistsAtPath:rootfulPath]) {
            basePath = rootfulPath;
        } else {
            NSLog(@"Failed to find ffmpeg framework at bundle, rootless or rootful paths");
            if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"ffmpeg framework not found"}];
            return NO;
        }
    #endif
    
    // Load libraries in dependency order. Use RTLD_GLOBAL so interdependencies resolve when
    // loading from separate framework dirs (e.g. libavcodec needs libavutil); RTLD_LOCAL
    // can cause dlopen to fail on jailbroken where the loader doesn't search other framework paths.
    int dlflags = RTLD_LAZY | RTLD_GLOBAL;
    libavutil_handle = dlopen([[basePath stringByAppendingPathComponent:@"libavutil.framework/libavutil"] UTF8String], dlflags);
    if (!libavutil_handle) {
        NSLog(@"Failed to load libavutil: %s", dlerror());
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load libavutil: %s", dlerror()]}];
        return NO;
    }
    
    libswscale_handle = dlopen([[basePath stringByAppendingPathComponent:@"libswscale.framework/libswscale"] UTF8String], dlflags);
    if (!libswscale_handle) {
        NSLog(@"Failed to load libswscale: %s", dlerror());
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load libswscale: %s", dlerror()]}];
        return NO;
    }
    
    libavcodec_handle = dlopen([[basePath stringByAppendingPathComponent:@"libavcodec.framework/libavcodec"] UTF8String], dlflags);
    if (!libavcodec_handle) {
        NSLog(@"Failed to load libavcodec: %s", dlerror());
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load libavcodec: %s", dlerror()]}];
        return NO;
    }
    
    libavformat_handle = dlopen([[basePath stringByAppendingPathComponent:@"libavformat.framework/libavformat"] UTF8String], dlflags);
    if (!libavformat_handle) {
        NSLog(@"Failed to load libavformat: %s", dlerror());
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load libavformat: %s", dlerror()]}];
        return NO;
    }
    
    // Load function pointers
    // avformat
    LOAD_FUNC(libavformat_handle, avformat_open_input);
    LOAD_FUNC(libavformat_handle, avformat_find_stream_info);
    LOAD_FUNC(libavformat_handle, avformat_close_input);
    LOAD_FUNC(libavformat_handle, avformat_alloc_output_context2);
    LOAD_FUNC(libavformat_handle, avformat_new_stream);
    LOAD_FUNC(libavformat_handle, avformat_write_header);
    LOAD_FUNC(libavformat_handle, avformat_free_context);
    LOAD_FUNC(libavformat_handle, av_read_frame);
    LOAD_FUNC(libavformat_handle, av_interleaved_write_frame);
    LOAD_FUNC(libavformat_handle, av_write_trailer);
    LOAD_FUNC(libavformat_handle, avio_open);
    LOAD_FUNC(libavformat_handle, avio_closep);
    LOAD_FUNC(libavformat_handle, av_guess_frame_rate);
    
    // avcodec
    LOAD_FUNC(libavcodec_handle, avcodec_find_decoder);
    LOAD_FUNC(libavcodec_handle, avcodec_find_encoder);
    LOAD_FUNC(libavcodec_handle, avcodec_find_encoder_by_name);
    LOAD_FUNC(libavcodec_handle, avcodec_alloc_context3);
    LOAD_FUNC(libavcodec_handle, avcodec_free_context);
    LOAD_FUNC(libavcodec_handle, avcodec_parameters_to_context);
    LOAD_FUNC(libavcodec_handle, avcodec_parameters_from_context);
    LOAD_FUNC(libavcodec_handle, avcodec_parameters_copy);
    LOAD_FUNC(libavcodec_handle, avcodec_open2);
    LOAD_FUNC(libavcodec_handle, avcodec_send_packet);
    LOAD_FUNC(libavcodec_handle, avcodec_receive_frame);
    LOAD_FUNC(libavcodec_handle, avcodec_send_frame);
    LOAD_FUNC(libavcodec_handle, avcodec_receive_packet);
    LOAD_FUNC(libavcodec_handle, avcodec_get_name);
    
    // Packet functions are in libavcodec (not libavutil)
    LOAD_FUNC(libavcodec_handle, av_packet_alloc);
    LOAD_FUNC(libavcodec_handle, av_packet_free);
    LOAD_FUNC(libavcodec_handle, av_packet_unref);
    LOAD_FUNC(libavcodec_handle, av_packet_rescale_ts);
    
    // avutil
    LOAD_FUNC(libavutil_handle, av_frame_alloc);
    LOAD_FUNC(libavutil_handle, av_frame_free);
    LOAD_FUNC(libavutil_handle, av_frame_get_buffer);
    LOAD_FUNC(libavutil_handle, av_frame_unref);
    LOAD_FUNC(libavutil_handle, av_opt_set);
    LOAD_FUNC(libavutil_handle, av_opt_set_int);
    LOAD_FUNC(libavutil_handle, av_strerror);
    
    // swscale
    LOAD_FUNC(libswscale_handle, sws_getContext);
    LOAD_FUNC(libswscale_handle, sws_scale);
    LOAD_FUNC(libswscale_handle, sws_freeContext);
    
    ffmpegLibrariesLoaded = YES;
    
    return YES;
}

// Helper to convert ffmpeg error codes to strings
static const char* av_err2str_helper(int errnum) {
    static char buf[128];
    p_av_strerror(errnum, buf, sizeof(buf));
    return buf;
}

/// Separate-audio demuxer (optional). Must be closed on every exit path once opened.
static void av1_close_audio_format_context(AVFormatContext **audioCtx) {
    if (audioCtx && *audioCtx) {
        p_avformat_close_input(audioCtx);
    }
}

@implementation AV1Transcoder

+ (BOOL)transcodeAV1ToH264:(NSString *)inputPath outputPath:(NSString *)outputPath audioPath:(NSString *)audioPath error:(NSError **)error progressBlock:(AV1TranscoderProgressBlock)progressBlock {
    // Load ffmpeg libraries dynamically
    if (!loadFFmpegLibraries(error)) {
        return NO;
    }
    
    if (progressBlock) progressBlock(@"Preparing.. (0%)", 0.0);
    
    AVFormatContext *inputFormatContext = NULL;
    AVFormatContext *audioFormatContext = NULL;  // Separate audio input
    AVCodecContext *decoderContext = NULL;
    AVCodecContext *encoderContext = NULL;
    AVFormatContext *outputFormatContext = NULL;
    AVStream *videoStream = NULL;
    AVStream *outputVideoStream = NULL;
    AVStream *mainInputAudioStream = NULL;
    AVStream *separateInputAudioStream = NULL;
    AVStream *outputAudioStream = NULL;
    struct SwsContext *swsContext = NULL;
    
    int ret = 0;
    int videoStreamIndex = -1;
    int audioStreamIndex = -1;
    int mainFileAudioStreamIndex = -1;  // Main input demuxer index; never alias to output index
    int audioStreamIndexInAudioFile = -1;  // Index within the separate audio file
    
    // Open input file
    ret = p_avformat_open_input(&inputFormatContext, [inputPath UTF8String], NULL, NULL);
    if (ret < 0) {
        NSLog(@"Could not open input file: %s", av_err2str_helper(ret));
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not open input file"}];
        return NO;
    }
    
    if (progressBlock) progressBlock(@"Analyzing.. (5%)", 0.05);
    
    // Find stream information
    ret = p_avformat_find_stream_info(inputFormatContext, NULL);
    if (ret < 0) {
        NSLog(@"Could not find stream info: %s", av_err2str_helper(ret));
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not find stream info"}];
        return NO;
    }
    
    // Find video and audio streams
    for (int i = 0; i < inputFormatContext->nb_streams; i++) {
        if (inputFormatContext->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && videoStreamIndex < 0) {
            videoStreamIndex = i;
            videoStream = inputFormatContext->streams[i];
        } else if (inputFormatContext->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audioStreamIndex < 0) {
            audioStreamIndex = i;
            mainFileAudioStreamIndex = i;
            mainInputAudioStream = inputFormatContext->streams[i];
        }
    }
    
    if (videoStreamIndex < 0) {
        NSLog(@"Could not find video stream");
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not find video stream"}];
        return NO;
    }
    
    // Log audio stream status
    if (audioStreamIndex >= 0) {
    } else {
        // If separate audio file is provided, try to open it
        if (audioPath && audioPath.length > 0) {
            ret = p_avformat_open_input(&audioFormatContext, [audioPath UTF8String], NULL, NULL);
            if (ret < 0) {
                NSLog(@"Warning: Could not open separate audio file: %s", av_err2str_helper(ret));
            } else {
                ret = p_avformat_find_stream_info(audioFormatContext, NULL);
                if (ret < 0) {
                    NSLog(@"Warning: Could not find audio stream info: %s", av_err2str_helper(ret));
                    p_avformat_close_input(&audioFormatContext);
                    audioFormatContext = NULL;
                } else {
                    // Find audio stream in separate file
                    for (int i = 0; i < audioFormatContext->nb_streams; i++) {
                        if (audioFormatContext->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                            audioStreamIndexInAudioFile = i;
                            separateInputAudioStream = audioFormatContext->streams[i];
                            break;
                        }
                    }
                    if (audioStreamIndexInAudioFile < 0) {
                        NSLog(@"Warning: No audio stream found in separate audio file");
                        p_avformat_close_input(&audioFormatContext);
                        audioFormatContext = NULL;
                    }
                    // Don't close audioFormatContext here - we'll read from it later!
                }
            }
        }
    }
    
    // Check for HDR
    BOOL isHDR = NO;
    if (videoStream->codecpar->color_primaries == AVCOL_PRI_BT2020 || 
        videoStream->codecpar->color_trc == AVCOL_TRC_SMPTE2084 ||
        videoStream->codecpar->color_trc == AVCOL_TRC_ARIB_STD_B67) {
        isHDR = YES;
    }
    
    // Get frame rate
    AVRational frameRate = p_av_guess_frame_rate(inputFormatContext, videoStream, NULL);
    double fps = (double)frameRate.num / frameRate.den;
    
    // Find AV1 decoder
    const AVCodec *decoder = p_avcodec_find_decoder(videoStream->codecpar->codec_id);
    if (!decoder) {
        NSLog(@"Could not find decoder for codec %s", p_avcodec_get_name(videoStream->codecpar->codec_id));
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not find AV1 decoder"}];
        return NO;
    }
    
    // Allocate decoder context
    decoderContext = p_avcodec_alloc_context3(decoder);
    if (!decoderContext) {
        NSLog(@"Could not allocate decoder context");
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not allocate decoder context"}];
        return NO;
    }
    
    // Copy codec parameters to decoder context
    ret = p_avcodec_parameters_to_context(decoderContext, videoStream->codecpar);
    if (ret < 0) {
        NSLog(@"Could not copy codec parameters: %s", av_err2str_helper(ret));
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not copy codec parameters"}];
        return NO;
    }
    
    // Enable multi-threading for AV1 decoder (CRITICAL for performance)
    decoderContext->thread_count = 0; // Auto-detect CPU cores
    decoderContext->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE; // Enable both frame and slice threading
    
    // Open decoder
    ret = p_avcodec_open2(decoderContext, decoder, NULL);
    if (ret < 0) {
        NSLog(@"Could not open decoder: %s", av_err2str_helper(ret));
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not open AV1 decoder"}];
        return NO;
    }
    
    if (progressBlock) progressBlock(@"Setting up.. (15%)", 0.15);
    
    // Create output format context
    ret = p_avformat_alloc_output_context2(&outputFormatContext, NULL, NULL, [outputPath UTF8String]);
    if (ret < 0) {
        NSLog(@"Could not create output context: %s", av_err2str_helper(ret));
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not create output context"}];
        return NO;
    }
    
    // Find encoder - Use HEVC for HDR content (better HDR support), H.264 for SDR
    const AVCodec *encoder = NULL;
    
    #ifdef SIDELOAD
        // For sideload builds, always use H.264 for better Photos compatibility
        // Photos app has issues with HEVC when saving via NSData in sandboxed apps
        encoder = p_avcodec_find_encoder_by_name("h264_videotoolbox");
        if (!encoder) {
            NSLog(@"VideoToolbox encoder not available, falling back to libx264");
            encoder = p_avcodec_find_encoder(AV_CODEC_ID_H264);
        }
    #else
        // For jailbreak builds, use HEVC for HDR content (full quality)
        if (isHDR) {
            // Try HEVC VideoToolbox first for HDR
            encoder = p_avcodec_find_encoder_by_name("hevc_videotoolbox");
            if (encoder) {
            } else {
                NSLog(@"HEVC VideoToolbox not available, trying software HEVC for HDR");
                encoder = p_avcodec_find_encoder(AV_CODEC_ID_HEVC);
            }
        }
        
        // Fall back to H.264 if HEVC not available or not HDR
        if (!encoder) {
            encoder = p_avcodec_find_encoder_by_name("h264_videotoolbox");
            if (!encoder) {
                encoder = p_avcodec_find_encoder(AV_CODEC_ID_H264);
            }
        }
    #endif
    
    if (!encoder) {
        NSLog(@"Could not find any suitable encoder");
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not find encoder"}];
        return NO;
    }
    
    // Create output video stream
    outputVideoStream = p_avformat_new_stream(outputFormatContext, NULL);
    if (!outputVideoStream) {
        NSLog(@"Could not create output video stream");
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not create output video stream"}];
        return NO;
    }
    
    // Allocate encoder context
    encoderContext = p_avcodec_alloc_context3(encoder);
    if (!encoderContext) {
        NSLog(@"Could not allocate encoder context");
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not allocate encoder context"}];
        return NO;
    }
    
    // Set encoder parameters
    encoderContext->width = decoderContext->width;
    encoderContext->height = decoderContext->height;
    
    // Preserve color space and HDR metadata
    encoderContext->color_primaries = decoderContext->color_primaries;
    encoderContext->color_trc = decoderContext->color_trc;
    encoderContext->colorspace = decoderContext->colorspace;
    encoderContext->color_range = decoderContext->color_range;
    
    // Use NV12 for VideoToolbox (native hardware format), YUV420P for software
    BOOL usingVideoToolbox = (strstr(encoder->name, "videotoolbox") != NULL);
    encoderContext->pix_fmt = usingVideoToolbox ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P;
    
    // Preserve original frame rate (important for 60fps, 120fps, etc.)
    encoderContext->time_base = videoStream->time_base;
    encoderContext->framerate = frameRate;
    
    // Set bitrate based on resolution and frame rate
    int pixels = encoderContext->width * encoderContext->height;
    double fpsMultiplier = fps / 30.0; // Scale bitrate with frame rate
    int baseBitrate = 8000000; // 8 Mbps base for 1080p30
    encoderContext->bit_rate = (int64_t)(baseBitrate * (pixels / 2073600.0) * fpsMultiplier); // Scale with resolution and fps
    
    encoderContext->gop_size = (int)(fps * 0.5); // GOP size = 0.5 seconds worth of frames
    
    // Check if we're using VideoToolbox or software encoder
    BOOL isHEVC = (encoder->id == AV_CODEC_ID_HEVC);
    
    if (usingVideoToolbox) {
        // VideoToolbox-specific settings (hardware encoder)
        encoderContext->max_b_frames = 0; // VideoToolbox doesn't use B-frames by default
        
        // VideoToolbox options
        p_av_opt_set(encoderContext->priv_data, "allow_sw", "0", 0); // Force hardware
        p_av_opt_set(encoderContext->priv_data, "realtime", "true", 0); // Real-time encoding
        p_av_opt_set_int(encoderContext->priv_data, "prio_speed", 1, 0); // Prioritize speed
    } else {
        // Software encoder settings
        encoderContext->max_b_frames = 2;
        encoderContext->thread_count = 0; // Auto-detect number of threads
        encoderContext->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
        
        if (isHEVC) {
            // x265 options for HEVC
            p_av_opt_set(encoderContext->priv_data, "preset", "fast", 0);
            if (isHDR) {
                // HDR settings for x265
                p_av_opt_set(encoderContext->priv_data, "hdr10", "1", 0);
            }
        } else {
            // x264 options for H.264
            p_av_opt_set(encoderContext->priv_data, "preset", "veryfast", 0);
            p_av_opt_set(encoderContext->priv_data, "profile", "high", 0);
            p_av_opt_set(encoderContext->priv_data, "crf", "23", 0);
        }
    }
    
    if (outputFormatContext->oformat->flags & AVFMT_GLOBALHEADER) {
        encoderContext->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    
    // Open encoder
    ret = p_avcodec_open2(encoderContext, encoder, NULL);
    if (ret < 0) {
        NSLog(@"Could not open encoder: %s", av_err2str_helper(ret));
        p_avcodec_free_context(&encoderContext);
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not open H.264 encoder"}];
        return NO;
    }
    
    // Copy encoder parameters to output stream
    ret = p_avcodec_parameters_from_context(outputVideoStream->codecpar, encoderContext);
    if (ret < 0) {
        NSLog(@"Could not copy encoder parameters: %s", av_err2str_helper(ret));
        p_avcodec_free_context(&encoderContext);
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not copy encoder parameters"}];
        return NO;
    }
    
    outputVideoStream->time_base = encoderContext->time_base;
    
    // Handle audio stream (copy without re-encoding if present)
    if (audioStreamIndex >= 0 || audioStreamIndexInAudioFile >= 0) {
        AVStream *audioStreamForOutput = mainInputAudioStream ?: separateInputAudioStream;
        if (!audioStreamForOutput) {
            NSLog(@"❌ ERROR: No source audio stream for output");
        } else {
            outputAudioStream = p_avformat_new_stream(outputFormatContext, NULL);
            if (!outputAudioStream) {
                NSLog(@"❌ ERROR: Could not create output audio stream - audio will be lost!");
            } else {
                ret = p_avcodec_parameters_copy(outputAudioStream->codecpar, audioStreamForOutput->codecpar);
                if (ret < 0) {
                    NSLog(@"❌ ERROR: Could not copy audio parameters: %s", av_err2str_helper(ret));
                }
                outputAudioStream->codecpar->codec_tag = 0;
                outputAudioStream->time_base = audioStreamForOutput->time_base;
            }
        }
    } else {
        NSLog(@"No audio stream to copy");
    }
    
    // Open output file
    if (!(outputFormatContext->oformat->flags & AVFMT_NOFILE)) {
        ret = p_avio_open(&outputFormatContext->pb, [outputPath UTF8String], AVIO_FLAG_WRITE);
        if (ret < 0) {
            NSLog(@"Could not open output file: %s", av_err2str_helper(ret));
            p_avcodec_free_context(&encoderContext);
            p_avformat_free_context(outputFormatContext);
            p_avcodec_free_context(&decoderContext);
            av1_close_audio_format_context(&audioFormatContext);
            p_avformat_close_input(&inputFormatContext);
            if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not open output file"}];
            return NO;
        }
    }
    
    // Write header
    ret = p_avformat_write_header(outputFormatContext, NULL);
    if (ret < 0) {
        NSLog(@"Could not write header: %s", av_err2str_helper(ret));
        p_avio_closep(&outputFormatContext->pb);
        p_avcodec_free_context(&encoderContext);
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:ret userInfo:@{NSLocalizedDescriptionKey: @"Could not write header"}];
        return NO;
    }
    
    if (progressBlock) progressBlock(@"Starting.. (20%)", 0.20);
    
    // Initialize scaler for pixel format conversion
    // Use fast scaler for speed while maintaining good quality
    int scalerFlags = SWS_FAST_BILINEAR | SWS_ACCURATE_RND; // Fast and accurate enough for video
    swsContext = p_sws_getContext(
        decoderContext->width, decoderContext->height, decoderContext->pix_fmt,
        encoderContext->width, encoderContext->height, encoderContext->pix_fmt,
        scalerFlags, NULL, NULL, NULL
    );
    
    if (!swsContext) {
        NSLog(@"Could not initialize scaler");
        p_av_write_trailer(outputFormatContext);
        p_avio_closep(&outputFormatContext->pb);
        p_avcodec_free_context(&encoderContext);
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not initialize scaler"}];
        return NO;
    }
    
    // Allocate frames
    AVFrame *decodedFrame = p_av_frame_alloc();
    AVFrame *encodedFrame = p_av_frame_alloc();
    AVPacket *packet = p_av_packet_alloc();
    AVPacket *outputPacket = p_av_packet_alloc();
    
    if (!decodedFrame || !encodedFrame || !packet || !outputPacket) {
        NSLog(@"Could not allocate frame or packet buffers");
        if (decodedFrame) p_av_frame_free(&decodedFrame);
        if (encodedFrame) p_av_frame_free(&encodedFrame);
        if (packet) p_av_packet_free(&packet);
        if (outputPacket) p_av_packet_free(&outputPacket);
        p_av_write_trailer(outputFormatContext);
        p_avio_closep(&outputFormatContext->pb);
        p_avcodec_free_context(&encoderContext);
        p_avformat_free_context(outputFormatContext);
        p_avcodec_free_context(&decoderContext);
        p_sws_freeContext(swsContext);
        av1_close_audio_format_context(&audioFormatContext);
        p_avformat_close_input(&inputFormatContext);
        if (error) *error = [NSError errorWithDomain:@"AV1Transcoder" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Could not allocate frame or packet buffers"}];
        return NO;
    }
    
    encodedFrame->format = encoderContext->pix_fmt;
    encodedFrame->width = encoderContext->width;
    encodedFrame->height = encoderContext->height;
    p_av_frame_get_buffer(encodedFrame, 0);
    
    int frameCount = 0;
    int audioPacketCount = 0;
    NSDate *startTime = [NSDate date];
    
    // Estimate total frames based on duration and framerate
    double duration = inputFormatContext->duration / (double)AV_TIME_BASE;
    int estimatedTotalFrames = (int)(duration * fps);
    if (estimatedTotalFrames == 0) estimatedTotalFrames = 300; // Default estimate if unknown
    
    // Read, decode, encode, and write frames
    while (p_av_read_frame(inputFormatContext, packet) >= 0) {
        if (packet->stream_index == videoStreamIndex) {
            // Send packet to decoder
            ret = p_avcodec_send_packet(decoderContext, packet);
            if (ret < 0 && ret != AVERROR(EAGAIN)) {
                NSLog(@"Error sending packet to decoder: %s", av_err2str_helper(ret));
                p_av_packet_unref(packet);
                continue;
            }
            // If EAGAIN, decoder buffer is full - just proceed to drain frames below
            
            // Receive decoded frames
            while (1) {
                ret = p_avcodec_receive_frame(decoderContext, decodedFrame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                    break;
                } else if (ret < 0) {
                    NSLog(@"Error receiving frame from decoder: %s", av_err2str_helper(ret));
                    break;
                }
                
                // Convert pixel format
                p_sws_scale(swsContext,
                         (const uint8_t * const *)decodedFrame->data, decodedFrame->linesize,
                         0, decoderContext->height,
                         encodedFrame->data, encodedFrame->linesize);
                
                // Preserve timing and color metadata
                encodedFrame->pts = decodedFrame->pts;
                encodedFrame->pkt_dts = decodedFrame->pkt_dts;
                encodedFrame->color_primaries = decodedFrame->color_primaries;
                encodedFrame->color_trc = decodedFrame->color_trc;
                encodedFrame->colorspace = decodedFrame->colorspace;
                encodedFrame->color_range = decodedFrame->color_range;
                
                // Send frame to encoder
                ret = p_avcodec_send_frame(encoderContext, encodedFrame);
                if (ret < 0 && ret != AVERROR(EAGAIN)) {
                    NSLog(@"Error sending frame to encoder: %s", av_err2str_helper(ret));
                    break;
                }
                
                // Receive encoded packets
                while (1) {
                    ret = p_avcodec_receive_packet(encoderContext, outputPacket);
                    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                        break;
                    } else if (ret < 0) {
                        NSLog(@"Error receiving packet from encoder: %s", av_err2str_helper(ret));
                        break;
                    }
                    
                    // Rescale timestamps
                    p_av_packet_rescale_ts(outputPacket, encoderContext->time_base, outputVideoStream->time_base);
                    outputPacket->stream_index = outputVideoStream->index;
                    
                    // Write packet
                    ret = p_av_interleaved_write_frame(outputFormatContext, outputPacket);
                    if (ret < 0) {
                        NSLog(@"Error writing packet: %s", av_err2str_helper(ret));
                    }
                    
                    p_av_packet_unref(outputPacket);
                    frameCount++;
                    
                    // Update progress periodically (every 30 frames to reduce overhead)
                    if (frameCount % 30 == 0) {
                        float progress = 0.20 + (0.75 * frameCount / (float)estimatedTotalFrames);
                        if (progress > 0.95) progress = 0.95; // Cap at 95% until actually done
                        
                        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startTime];
                        double currentFps = frameCount / elapsed;
                        
                        if (progressBlock) {
                            // Calculate time remaining
                            float fractionComplete = frameCount / (float)estimatedTotalFrames;
                            if (fractionComplete > 0.01) { // Avoid division issues early on
                                NSTimeInterval estimatedTotal = elapsed / fractionComplete;
                                NSTimeInterval remaining = estimatedTotal - elapsed;
                                
                                // Format time remaining
                                int remainingMinutes = (int)(remaining / 60);
                                int remainingSeconds = (int)remaining % 60;
                                
                                // Calculate percentage
                                int percentage = (int)(progress * 100);
                                
                                NSString *timeString;
                                if (remaining < 1) {
                                    timeString = @"Almost done";
                                } else if (remainingMinutes > 0) {
                                    timeString = [NSString stringWithFormat:@"%dm %ds left", remainingMinutes, remainingSeconds];
                                } else {
                                    timeString = [NSString stringWithFormat:@"%ds left", remainingSeconds];
                                }
                                
                                NSString *status = [NSString stringWithFormat:@"Working.. (%d%% | %@)", percentage, timeString];
                                progressBlock(status, progress);
                            }
                        }
                    }
                }
                
                p_av_frame_unref(decodedFrame);
            }
        } else if (mainFileAudioStreamIndex >= 0 && packet->stream_index == mainFileAudioStreamIndex) {
            // Copy audio packet without re-encoding
            if (outputAudioStream && mainInputAudioStream) {
                p_av_packet_rescale_ts(packet, mainInputAudioStream->time_base, outputAudioStream->time_base);
                packet->stream_index = outputAudioStream->index;
                ret = p_av_interleaved_write_frame(outputFormatContext, packet);
                if (ret < 0) {
                    if (audioPacketCount == 0) {
                        NSLog(@"❌ Error writing first audio packet: %s", av_err2str_helper(ret));
                    }
                } else {
                    audioPacketCount++;
                }
            } else {
                if (audioPacketCount == 0) {
                    NSLog(@"❌ Skipping audio packets - output audio stream not created");
                }
            }
        }
        
        p_av_packet_unref(packet);
    }
    
    // If we have a separate audio file, read and copy all audio packets from it
    if (audioFormatContext && audioStreamIndexInAudioFile >= 0 && outputAudioStream) {
        AVPacket *audioPacket = p_av_packet_alloc();
        if (!audioPacket) {
            NSLog(@"❌ Could not allocate AVPacket for separate audio track");
        } else {
            int audioPacketsRead = 0;

            while (p_av_read_frame(audioFormatContext, audioPacket) >= 0) {
                if (audioPacket->stream_index == audioStreamIndexInAudioFile) {
                    // Copy audio packet without re-encoding (use separate file's stream time base)
                    p_av_packet_rescale_ts(audioPacket, separateInputAudioStream->time_base, outputAudioStream->time_base);
                    audioPacket->stream_index = outputAudioStream->index;
                    ret = p_av_interleaved_write_frame(outputFormatContext, audioPacket);
                    if (ret < 0) {
                        if (audioPacketsRead == 0) {
                            NSLog(@"❌ Error writing first audio packet from separate file: %s", av_err2str_helper(ret));
                        }
                    } else {
                        audioPacketsRead++;
                        audioPacketCount++;
                    }
                }
                p_av_packet_unref(audioPacket);
            }

            p_av_packet_free(&audioPacket);

            if (audioPacketsRead == 0) {
                NSLog(@"❌ WARNING: No audio packets were read from separate file!");
            }
        }
    }
    
    // Flush decoder
    p_avcodec_send_packet(decoderContext, NULL);
    while (p_avcodec_receive_frame(decoderContext, decodedFrame) >= 0) {
        p_sws_scale(swsContext,
                 (const uint8_t * const *)decodedFrame->data, decodedFrame->linesize,
                 0, decoderContext->height,
                 encodedFrame->data, encodedFrame->linesize);
        encodedFrame->pts = decodedFrame->pts;
        p_avcodec_send_frame(encoderContext, encodedFrame);
        while (p_avcodec_receive_packet(encoderContext, outputPacket) >= 0) {
            p_av_packet_rescale_ts(outputPacket, encoderContext->time_base, outputVideoStream->time_base);
            outputPacket->stream_index = outputVideoStream->index;
            p_av_interleaved_write_frame(outputFormatContext, outputPacket);
            p_av_packet_unref(outputPacket);
            frameCount++;
        }
        p_av_frame_unref(decodedFrame);
    }
    
    // Flush encoder
    p_avcodec_send_frame(encoderContext, NULL);
    while (p_avcodec_receive_packet(encoderContext, outputPacket) >= 0) {
        p_av_packet_rescale_ts(outputPacket, encoderContext->time_base, outputVideoStream->time_base);
        outputPacket->stream_index = outputVideoStream->index;
        p_av_interleaved_write_frame(outputFormatContext, outputPacket);
        p_av_packet_unref(outputPacket);
        frameCount++;
    }
    
    NSTimeInterval totalTime = [[NSDate date] timeIntervalSinceDate:startTime];
    double avgFps = frameCount / totalTime;
    double processingRatio = totalTime / duration; // How many seconds to process 1 second of video
    
    if (mainFileAudioStreamIndex >= 0 || audioStreamIndexInAudioFile >= 0) {
    } else {
        NSLog(@"ℹ️ No audio in source");
    }
    
    if (progressBlock) progressBlock(@"Finalizing.. (98%)", 0.98);
    
    // Write trailer
    p_av_write_trailer(outputFormatContext);
    
    // Cleanup
    p_av_frame_free(&decodedFrame);
    p_av_frame_free(&encodedFrame);
    p_av_packet_free(&packet);
    p_av_packet_free(&outputPacket);
    p_sws_freeContext(swsContext);
    p_avcodec_free_context(&decoderContext);
    p_avcodec_free_context(&encoderContext);
    p_avio_closep(&outputFormatContext->pb);
    p_avformat_free_context(outputFormatContext);
    p_avformat_close_input(&inputFormatContext);
    av1_close_audio_format_context(&audioFormatContext);
    return YES;
}

@end
