#import "Include/ThetaDashManifest.h"
#import <Photos/Photos.h>

NSString *IGDashManifestBestQualityURL(NSString *manifest) {
    NSArray *videoPatterns = @[
        @"<AdaptationSet id=\"0\" contentType=\"video\"",
        @"<AdaptationSet id=\"1\" contentType=\"video\"",
        @"<AdaptationSet contentType=\"video\"",
        @"<AdaptationSet id=\"0\" contentType=\"Video\"",
        @"<AdaptationSet id=\"1\" contentType=\"Video\"",
        @"<AdaptationSet contentType=\"Video\""
    ];

    NSRange videoSetRange = NSMakeRange(NSNotFound, 0);
    for (NSString *pattern in videoPatterns) {
        videoSetRange = [manifest rangeOfString:pattern options:NSCaseInsensitiveSearch];
        if (videoSetRange.location != NSNotFound) break;
    }

    if (videoSetRange.location == NSNotFound) return nil;
    NSRange videoSearchRange = NSMakeRange(videoSetRange.location, manifest.length - videoSetRange.location);

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"FBQualityLabel=\\\"(\\d+)p\\\"" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:manifest options:0 range:videoSearchRange];

    NSInteger highestQuality = 0;

    if (matches.count > 0) {
        for (NSTextCheckingResult *match in matches) {
            NSString *qualityString = [manifest substringWithRange:[match rangeAtIndex:1]];
            NSInteger quality = [qualityString integerValue];
            if (quality > highestQuality) {
                highestQuality = quality;
            }
        }
    } else {
        NSRegularExpression *bandwidthRegex = [NSRegularExpression regularExpressionWithPattern:@"bandwidth=\\\"(\\d+)\\\"" options:NSRegularExpressionCaseInsensitive error:nil];
        NSArray<NSTextCheckingResult *> *bandwidthMatches = [bandwidthRegex matchesInString:manifest options:0 range:videoSearchRange];

        NSInteger highestBandwidth = 0;
        NSRange bestBandwidthRange = NSMakeRange(NSNotFound, 0);

        for (NSTextCheckingResult *match in bandwidthMatches) {
            NSString *bandwidthString = [manifest substringWithRange:[match rangeAtIndex:1]];
            NSInteger bandwidth = [bandwidthString integerValue];
            if (bandwidth > highestBandwidth) {
                highestBandwidth = bandwidth;
                bestBandwidthRange = match.range;
            }
        }

        if (bestBandwidthRange.location != NSNotFound) {
            NSRange searchStart = NSMakeRange(bestBandwidthRange.location, manifest.length - bestBandwidthRange.location);
            NSRange baseURLStart = [manifest rangeOfString:@"<BaseURL>" options:0 range:searchStart];
            NSRange baseURLEnd = [manifest rangeOfString:@"</BaseURL>" options:0 range:searchStart];

            if (baseURLStart.location != NSNotFound && baseURLEnd.location != NSNotFound) {
                NSUInteger urlStart = baseURLStart.location + baseURLStart.length;
                NSUInteger urlLength = baseURLEnd.location - urlStart;
                NSString *url = [manifest substringWithRange:NSMakeRange(urlStart, urlLength)];
                url = [url stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
                return url;
            }
        }

        return nil;
    }

    if (highestQuality == 0) return nil;
    NSString *bestQualityLabel = [NSString stringWithFormat:@"%ldp", (long)highestQuality];

    NSString *search = [NSString stringWithFormat:@"FBQualityLabel=\"%@\"", bestQualityLabel];
    NSRange qualityRange = [manifest rangeOfString:search options:NSBackwardsSearch range:videoSearchRange];
    if (qualityRange.location == NSNotFound) return nil;

    NSRange baseURLSearchRange = NSMakeRange(qualityRange.location, manifest.length - qualityRange.location);
    NSRange baseURLStart = [manifest rangeOfString:@"<BaseURL>" options:0 range:baseURLSearchRange];
    NSRange baseURLEnd = [manifest rangeOfString:@"</BaseURL>" options:0 range:baseURLSearchRange];
    if (baseURLStart.location == NSNotFound || baseURLEnd.location == NSNotFound) return nil;

    NSUInteger urlStart = baseURLStart.location + baseURLStart.length;
    NSUInteger urlLength = baseURLEnd.location - urlStart;
    NSString *url = [manifest substringWithRange:NSMakeRange(urlStart, urlLength)];
    url = [url stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return url;
}

NSString *IGDashManifestBestCompatibleURL(NSString *manifest) {
    NSArray *videoPatterns = @[
        @"<AdaptationSet id=\"0\" contentType=\"video\"",
        @"<AdaptationSet id=\"1\" contentType=\"video\"",
        @"<AdaptationSet contentType=\"video\"",
        @"<AdaptationSet id=\"0\" contentType=\"Video\"",
        @"<AdaptationSet id=\"1\" contentType=\"Video\"",
        @"<AdaptationSet contentType=\"Video\""
    ];

    NSRange videoSetRange = NSMakeRange(NSNotFound, 0);
    for (NSString *pattern in videoPatterns) {
        videoSetRange = [manifest rangeOfString:pattern options:NSCaseInsensitiveSearch];
        if (videoSetRange.location != NSNotFound) break;
    }

    if (videoSetRange.location == NSNotFound) {
        return nil;
    }

    NSRange videoSearchRange = NSMakeRange(videoSetRange.location, manifest.length - videoSetRange.location);

    NSRegularExpression *repRegex = [NSRegularExpression regularExpressionWithPattern:@"<Representation[^>]*codecs=\"([^\"]+)\"[^>]*FBQualityLabel=\"(\\d+)p\"[^>]*>" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *repMatches = [repRegex matchesInString:manifest options:0 range:videoSearchRange];

    NSRegularExpression *repRegexAlt = [NSRegularExpression regularExpressionWithPattern:@"<Representation[^>]*FBQualityLabel=\"(\\d+)p\"[^>]*codecs=\"([^\"]+)\"[^>]*>" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *repMatchesAlt = [repRegexAlt matchesInString:manifest options:0 range:videoSearchRange];

    NSInteger bestCompatibleQuality = 0;
    NSRange bestCompatibleRepRange = NSMakeRange(NSNotFound, 0);

    for (NSTextCheckingResult *match in repMatches) {
        NSString *codec = [manifest substringWithRange:[match rangeAtIndex:1]];
        NSString *qualityStr = [manifest substringWithRange:[match rangeAtIndex:2]];
        NSInteger quality = [qualityStr integerValue];
        BOOL isCompatible = [codec hasPrefix:@"avc1"] || [codec hasPrefix:@"hvc1"] || [codec hasPrefix:@"hev1"];
        if (isCompatible && quality > bestCompatibleQuality) {
            bestCompatibleQuality = quality;
            bestCompatibleRepRange = match.range;
        }
    }

    for (NSTextCheckingResult *match in repMatchesAlt) {
        NSString *qualityStr = [manifest substringWithRange:[match rangeAtIndex:1]];
        NSString *codec = [manifest substringWithRange:[match rangeAtIndex:2]];
        NSInteger quality = [qualityStr integerValue];
        BOOL isCompatible = [codec hasPrefix:@"avc1"] || [codec hasPrefix:@"hvc1"] || [codec hasPrefix:@"hev1"];
        if (isCompatible && quality > bestCompatibleQuality) {
            bestCompatibleQuality = quality;
            bestCompatibleRepRange = match.range;
        }
    }

    if (bestCompatibleRepRange.location != NSNotFound) {
        NSRange searchStart = NSMakeRange(bestCompatibleRepRange.location, manifest.length - bestCompatibleRepRange.location);
        NSRange baseURLStart = [manifest rangeOfString:@"<BaseURL>" options:0 range:searchStart];
        NSRange baseURLEnd = [manifest rangeOfString:@"</BaseURL>" options:0 range:searchStart];

        if (baseURLStart.location != NSNotFound && baseURLEnd.location != NSNotFound) {
            NSUInteger urlStart = baseURLStart.location + baseURLStart.length;
            NSUInteger urlLength = baseURLEnd.location - urlStart;
            NSString *url = [manifest substringWithRange:NSMakeRange(urlStart, urlLength)];
            url = [url stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            return url;
        }
    }

    return IGDashManifestBestQualityURL(manifest);
}

static NSString *ThetaDashExtractBaseURLAfterRangeInBlock(NSString *block, NSRange repTagRange) {
    NSRange afterRep = NSMakeRange(NSMaxRange(repTagRange), block.length - NSMaxRange(repTagRange));
    NSRange nextRep = [block rangeOfString:@"<Representation" options:0 range:afterRep];
    NSRange searchLimit;
    if (nextRep.location == NSNotFound) {
        searchLimit = afterRep;
    } else {
        searchLimit = NSMakeRange(afterRep.location, nextRep.location - afterRep.location);
    }
    NSRange baseStart = [block rangeOfString:@"<BaseURL>" options:0 range:searchLimit];
    NSRange baseEnd = [block rangeOfString:@"</BaseURL>" options:0 range:searchLimit];
    if (baseStart.location == NSNotFound || baseEnd.location == NSNotFound) return nil;
    NSUInteger uStart = baseStart.location + baseStart.length;
    NSString *u = [block substringWithRange:NSMakeRange(uStart, baseEnd.location - uStart)];
    return [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

NSString *IGDashManifestBestAudioURL(NSString *manifest) {
    if (!manifest.length) return nil;

    NSError *err = nil;
    NSRegularExpression *setRe = [NSRegularExpression regularExpressionWithPattern:@"<AdaptationSet\\b[^>]*contentType=\\\"audio\\\"[^>]*>" options:NSRegularExpressionCaseInsensitive error:&err];
    NSArray<NSTextCheckingResult *> *setMatches = [setRe matchesInString:manifest options:0 range:NSMakeRange(0, manifest.length)];

    NSUInteger bestBW = 0;
    NSString *bestURL = nil;

    for (NSTextCheckingResult *setMatch in setMatches) {
        NSRange fromStart = NSMakeRange(setMatch.range.location, manifest.length - setMatch.range.location);
        NSRange close = [manifest rangeOfString:@"</AdaptationSet>" options:0 range:fromStart];
        if (close.location == NSNotFound) continue;

        NSRange blockRange = NSMakeRange(setMatch.range.location, NSMaxRange(close) - setMatch.range.location);
        NSString *block = [manifest substringWithRange:blockRange];

        NSRegularExpression *repWithBW = [NSRegularExpression regularExpressionWithPattern:@"<Representation\\b[^>]*bandwidth=\\\"(\\d+)\\\"[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
        NSArray<NSTextCheckingResult *> *repMatches = [repWithBW matchesInString:block options:0 range:NSMakeRange(0, block.length)];
        for (NSTextCheckingResult *rm in repMatches) {
            NSUInteger bw = (NSUInteger)[[block substringWithRange:[rm rangeAtIndex:1]] longLongValue];
            NSString *u = ThetaDashExtractBaseURLAfterRangeInBlock(block, rm.range);
            if (!u.length) continue;
            if (bw >= bestBW) {
                bestBW = bw;
                bestURL = u;
            }
        }
    }

    if (!bestURL.length && setMatches.count) {
        for (NSTextCheckingResult *setMatch in setMatches) {
            NSRange fromStart = NSMakeRange(setMatch.range.location, manifest.length - setMatch.range.location);
            NSRange close = [manifest rangeOfString:@"</AdaptationSet>" options:0 range:fromStart];
            if (close.location == NSNotFound) continue;
            NSRange blockRange = NSMakeRange(setMatch.range.location, NSMaxRange(close) - setMatch.range.location);
            NSString *block = [manifest substringWithRange:blockRange];
            NSRegularExpression *fallbackRep = [NSRegularExpression regularExpressionWithPattern:@"<Representation\\b[^>]*>" options:0 error:nil];
            NSArray<NSTextCheckingResult *> *fb = [fallbackRep matchesInString:block options:0 range:NSMakeRange(0, block.length)];
            if (!fb.count) continue;
            NSString *u = ThetaDashExtractBaseURLAfterRangeInBlock(block, fb.lastObject.range);
            if (u.length) {
                bestURL = u;
                break;
            }
        }
    }

    if (bestURL.length) return bestURL;

    NSArray *legacyPatterns = @[
        @"<AdaptationSet id=\"0\" contentType=\"audio\"",
        @"<AdaptationSet id=\"1\" contentType=\"audio\"",
        @"<AdaptationSet id=\"2\" contentType=\"audio\"",
        @"<AdaptationSet contentType=\"audio\"",
        @"<AdaptationSet id=\"0\" contentType=\"Audio\"",
        @"<AdaptationSet id=\"1\" contentType=\"Audio\""
    ];

    NSRange audioSetRange = NSMakeRange(NSNotFound, 0);
    for (NSString *pattern in legacyPatterns) {
        audioSetRange = [manifest rangeOfString:pattern options:NSCaseInsensitiveSearch];
        if (audioSetRange.location != NSNotFound) break;
    }

    if (audioSetRange.location == NSNotFound) return nil;
    NSRange audioSearchRange = NSMakeRange(audioSetRange.location, manifest.length - audioSetRange.location);
    NSRange adaptationSetEndRange = [manifest rangeOfString:@"</AdaptationSet>" options:0 range:audioSearchRange];
    if (adaptationSetEndRange.location == NSNotFound) return nil;

    audioSearchRange = NSMakeRange(audioSetRange.location, adaptationSetEndRange.location - audioSetRange.location + adaptationSetEndRange.length);
    NSString *block = [manifest substringWithRange:audioSearchRange];

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<Representation\\b[^>]*>" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:block options:0 range:NSMakeRange(0, block.length)];
    if (matches.count == 0) return nil;

    NSTextCheckingResult *lastMatch = matches.lastObject;
    NSString *u = ThetaDashExtractBaseURLAfterRangeInBlock(block, lastMatch.range);
    return u.length ? u : nil;
}

void ThetaPhotoLibraryImportVideoFromURL(NSURL *fileURL, void (^completion)(BOOL success, NSError *error)) {
    if (!fileURL) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ThetaDashManifest" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Missing file URL"}]);
        return;
    }
#if defined(SIDELOAD)
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
    } completionHandler:^(BOOL success, NSError *_Nullable error) {
        if (completion) completion(success, error);
    }];
#else
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
        PHAssetResourceCreationOptions *opts = [PHAssetResourceCreationOptions new];
        opts.shouldMoveFile = NO;
        [req addResourceWithType:PHAssetResourceTypeVideo fileURL:fileURL options:opts];
    } completionHandler:^(BOOL success, NSError *_Nullable error) {
        if (completion) completion(success, error);
    }];
#endif
}
