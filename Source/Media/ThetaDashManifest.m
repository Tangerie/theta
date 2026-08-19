#import "Include/ThetaDashManifest.h"
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>

static NSString *ThetaDashExtractBaseURLAfterRangeInBlock(NSString *block, NSRange repTagRange);

@implementation ThetaDashVideoQuality
- (BOOL)isAV1 {
    NSString *codecs = self.codecs ?: @"";
    return [codecs hasPrefix:@"av01"] || [codecs.lowercaseString hasPrefix:@"av1"];
}
- (NSString *)menuTitleIncludingCodec:(BOOL)includeCodec {
    NSString *label = self.label.length ? self.label : @"Video";
    if (includeCodec && self.codecName.length) {
        return [NSString stringWithFormat:@"%@ · %@", label, self.codecName];
    }
    return label;
}
- (NSString *)menuSubtitle {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (self.estimatedOutputBytes > 0) {
        [parts addObject:[NSString stringWithFormat:@"~%@", ThetaDashFormatByteCount(self.estimatedOutputBytes)]];
    }
    if (self.codecName.length && ![self.codecName isEqualToString:@"Video"]) {
        [parts addObject:self.codecName];
    }
    return [parts componentsJoinedByString:@" · "];
}
@end

NSString *ThetaDashFormatByteCount(unsigned long long bytes) {
    if (bytes < 1024ULL) {
        return [NSString stringWithFormat:@"%llu B", bytes];
    }
    double kb = bytes / 1024.0;
    if (kb < 1024.0) {
        return [NSString stringWithFormat:@"%.0f KB", kb];
    }
    double mb = kb / 1024.0;
    if (mb < 1024.0) {
        return [NSString stringWithFormat:(mb >= 10.0 ? @"%.0f MB" : @"%.1f MB"), mb];
    }
    return [NSString stringWithFormat:@"%.2f GB", mb / 1024.0];
}

static NSString *ThetaDashXMLAttr(NSString *tag, NSString *name) {
    if (!tag.length || !name.length) return nil;
    NSString *pattern = [NSString stringWithFormat:@"%@\\s*=\\s*[\"']([^\"']*)[\"']", name];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [tag substringWithRange:[match rangeAtIndex:1]];
}

static NSTimeInterval ThetaDashParseISODuration(NSString *value) {
    if (!value.length) return 0;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"PT(?:(\\d+)H)?(?:(\\d+)M)?(?:([\\d.]+)S)?" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    if (!match) return 0;
    double hours = 0, minutes = 0, seconds = 0;
    if ([match rangeAtIndex:1].location != NSNotFound) {
        hours = [[value substringWithRange:[match rangeAtIndex:1]] doubleValue];
    }
    if ([match rangeAtIndex:2].location != NSNotFound) {
        minutes = [[value substringWithRange:[match rangeAtIndex:2]] doubleValue];
    }
    if ([match rangeAtIndex:3].location != NSNotFound) {
        seconds = [[value substringWithRange:[match rangeAtIndex:3]] doubleValue];
    }
    return (hours * 3600.0) + (minutes * 60.0) + seconds;
}

NSTimeInterval ThetaDashManifestDuration(NSString *manifest) {
    if (!manifest.length) return 0;
    NSArray<NSString *> *patterns = @[
        @"mediaPresentationDuration\\s*=\\s*\"([^\"]+)\"",
        @"<Period\\b[^>]*\\bduration\\s*=\\s*\"([^\"]+)\""
    ];
    for (NSString *pattern in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *match = [re firstMatchInString:manifest options:0 range:NSMakeRange(0, manifest.length)];
        if (!match || match.numberOfRanges < 2) continue;
        NSTimeInterval duration = ThetaDashParseISODuration([manifest substringWithRange:[match rangeAtIndex:1]]);
        if (duration > 0.05) return duration;
    }
    return 0;
}

static double ThetaDashParseFrameRate(NSString *value) {
    if (!value.length) return 0;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"/"];
    if (parts.count == 2) {
        double numerator = [parts[0] doubleValue];
        double denominator = [parts[1] doubleValue];
        if (denominator > 0) return numerator / denominator;
    }
    return [value doubleValue];
}

static NSString *ThetaDashCodecDisplayName(NSString *codecs) {
    NSString *value = codecs ?: @"";
    NSString *lower = value.lowercaseString;
    if ([lower hasPrefix:@"av01"] || [lower hasPrefix:@"av1"]) return @"AV1";
    if ([lower hasPrefix:@"avc1"] || [lower hasPrefix:@"avc3"]) return @"H.264";
    if ([lower hasPrefix:@"hvc1"] || [lower hasPrefix:@"hev1"]) return @"HEVC";
    if ([lower hasPrefix:@"vp09"] || [lower hasPrefix:@"vp9"]) return @"VP9";
    return value.length ? value : @"Video";
}

static NSInteger ThetaDashCodecSortRank(NSString *codecName) {
    if ([codecName isEqualToString:@"H.264"]) return 0;
    if ([codecName isEqualToString:@"HEVC"]) return 1;
    if ([codecName isEqualToString:@"AV1"]) return 2;
    return 3;
}

static unsigned long long ThetaDashEstimateConvertedBytes(NSInteger width, NSInteger height, NSInteger quality, double frameRate, NSTimeInterval duration, NSUInteger audioBandwidth) {
    NSInteger shortSide = quality > 0 ? quality : 0;
    if (shortSide <= 0 && width > 0 && height > 0) {
        shortSide = MIN(width, height);
    }
    if (shortSide <= 0) shortSide = 720;
    NSInteger longSide = (NSInteger)llround((double)shortSide * 16.0 / 9.0);
    double fps = frameRate > 1.0 ? frameRate : 30.0;
    if (fps > 60.0) fps = 60.0;
    double seconds = duration > 0.05 ? duration : 0;
    if (seconds <= 0) return 0;

    // HighestQuality H.264 ≈ 0.10 bits/pixel for vertical reels.
    double videoBps = (double)shortSide * (double)longSide * fps * 0.10;
    if (videoBps < 200000.0) videoBps = 200000.0;
    if (videoBps > 12000000.0) videoBps = 12000000.0;
    double audioBps = audioBandwidth > 0 ? (double)audioBandwidth : 128000.0;
    if (audioBps < 96000.0) audioBps = 128000.0;
    return (unsigned long long)llround((videoBps + audioBps) * seconds / 8.0 * 1.03);
}

static NSUInteger ThetaDashBestAudioBandwidth(NSString *manifest) {
    if (!manifest.length) return 0;
    NSRegularExpression *setRe = [NSRegularExpression regularExpressionWithPattern:@"<AdaptationSet\\b[^>]*contentType=\\\"audio\\\"[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray<NSTextCheckingResult *> *setMatches = [setRe matchesInString:manifest options:0 range:NSMakeRange(0, manifest.length)];
    NSUInteger bestBW = 0;
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
            if (bw > bestBW) bestBW = bw;
        }
    }
    return bestBW;
}

NSArray<ThetaDashVideoQuality *> *ThetaDashManifestVideoQualities(NSString *manifest, NSTimeInterval fallbackDuration) {
    if (!manifest.length) return @[];

    NSTimeInterval duration = ThetaDashManifestDuration(manifest);
    if (duration <= 0.05) duration = fallbackDuration;
    NSUInteger audioBandwidth = ThetaDashBestAudioBandwidth(manifest);

    NSRegularExpression *setRe = [NSRegularExpression regularExpressionWithPattern:@"<AdaptationSet\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray<NSTextCheckingResult *> *setMatches = [setRe matchesInString:manifest options:0 range:NSMakeRange(0, manifest.length)];
    NSMutableArray<ThetaDashVideoQuality *> *found = [NSMutableArray array];

    for (NSTextCheckingResult *setMatch in setMatches) {
        NSString *setTag = [manifest substringWithRange:setMatch.range];
        NSString *contentType = [ThetaDashXMLAttr(setTag, @"contentType") lowercaseString];
        if ([contentType isEqualToString:@"audio"]) continue;

        NSRange fromStart = NSMakeRange(setMatch.range.location, manifest.length - setMatch.range.location);
        NSRange close = [manifest rangeOfString:@"</AdaptationSet>" options:0 range:fromStart];
        if (close.location == NSNotFound) continue;
        NSRange blockRange = NSMakeRange(setMatch.range.location, NSMaxRange(close) - setMatch.range.location);
        NSString *block = [manifest substringWithRange:blockRange];

        BOOL looksLikeVideo = [contentType isEqualToString:@"video"]
            || [block.lowercaseString containsString:@"fbqualitylabel"]
            || [block.lowercaseString containsString:@"codecs=\"av01"]
            || [block.lowercaseString containsString:@"codecs=\"avc1"]
            || [block.lowercaseString containsString:@"codecs=\"hvc1"]
            || [block.lowercaseString containsString:@"codecs=\"hev1"];
        if (!looksLikeVideo) continue;

        NSRegularExpression *repRe = [NSRegularExpression regularExpressionWithPattern:@"<Representation\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
        NSArray<NSTextCheckingResult *> *repMatches = [repRe matchesInString:block options:0 range:NSMakeRange(0, block.length)];
        for (NSTextCheckingResult *rm in repMatches) {
            NSString *tag = [block substringWithRange:rm.range];
            NSString *url = ThetaDashExtractBaseURLAfterRangeInBlock(block, rm.range);
            url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!url.length) continue;

            NSString *codecs = ThetaDashXMLAttr(tag, @"codecs") ?: @"";
            NSString *codecName = ThetaDashCodecDisplayName(codecs);
            if ([codecName isEqualToString:@"Video"] && ![contentType isEqualToString:@"video"]) continue;

            NSInteger width = [ThetaDashXMLAttr(tag, @"width") integerValue];
            NSInteger height = [ThetaDashXMLAttr(tag, @"height") integerValue];
            NSString *label = ThetaDashXMLAttr(tag, @"FBQualityLabel");
            NSInteger quality = 0;
            if (label.length) {
                quality = [label integerValue];
            } else if (width > 0 || height > 0) {
                quality = MIN(width > 0 ? width : height, height > 0 ? height : width);
                label = [NSString stringWithFormat:@"%ldp", (long)quality];
            } else {
                label = @"Video";
            }

            NSString *bwString = ThetaDashXMLAttr(tag, @"bandwidth");
            if (!bwString.length) bwString = ThetaDashXMLAttr(tag, @"FBBandwidth");
            NSUInteger bandwidth = (NSUInteger)[bwString longLongValue];
            NSString *fpsString = ThetaDashXMLAttr(tag, @"frameRate");
            if (!fpsString.length) fpsString = ThetaDashXMLAttr(tag, @"FBAvgFramerate");

            ThetaDashVideoQuality *item = [ThetaDashVideoQuality new];
            item.url = url;
            item.label = label;
            item.codecs = codecs;
            item.codecName = codecName;
            item.width = width;
            item.height = height;
            item.quality = quality;
            item.bandwidth = bandwidth;
            item.frameRate = ThetaDashParseFrameRate(fpsString);
            item.duration = duration;
            item.estimatedOutputBytes = ThetaDashEstimateConvertedBytes(width, height, quality, item.frameRate, duration, audioBandwidth);
            [found addObject:item];
        }
    }

    NSMutableDictionary<NSString *, ThetaDashVideoQuality *> *bestByKey = [NSMutableDictionary dictionary];
    NSMutableArray<ThetaDashVideoQuality *> *unkeyed = [NSMutableArray array];
    for (ThetaDashVideoQuality *item in found) {
        if (item.quality <= 0) {
            [unkeyed addObject:item];
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%ld-%@", (long)item.quality, item.codecName ?: @""];
        ThetaDashVideoQuality *existing = bestByKey[key];
        if (!existing || item.bandwidth > existing.bandwidth) {
            bestByKey[key] = item;
        }
    }

    NSMutableArray<ThetaDashVideoQuality *> *qualities = [[bestByKey allValues] mutableCopy];
    [qualities addObjectsFromArray:unkeyed];
    [qualities sortUsingComparator:^NSComparisonResult(ThetaDashVideoQuality *a, ThetaDashVideoQuality *b) {
        if (a.quality != b.quality) {
            return a.quality > b.quality ? NSOrderedAscending : NSOrderedDescending;
        }
        NSInteger rankA = ThetaDashCodecSortRank(a.codecName);
        NSInteger rankB = ThetaDashCodecSortRank(b.codecName);
        if (rankA != rankB) {
            return rankA < rankB ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.bandwidth != b.bandwidth) {
            return a.bandwidth > b.bandwidth ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    return [qualities copy];
}

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

static NSInteger ThetaDashAudioCompatibilityScore(NSString *codecs) {
    NSString *c = codecs.lowercaseString ?: @"";
    if ([c hasPrefix:@"mp4a.40.2"]) return 400;   // AAC-LC
    if ([c hasPrefix:@"mp4a.40.5"]) return 300;   // HE-AAC
    if ([c hasPrefix:@"mp4a.40.29"]) return 250;  // HE-AACv2
    if ([c hasPrefix:@"mp4a.40.42"]) return 20;   // xHE-AAC / USAC
    if ([c hasPrefix:@"mp4a"]) return 200;
    if ([c containsString:@"opus"]) return 80;
    if ([c hasPrefix:@"ec-3"] || [c hasPrefix:@"ac-3"]) return 60;
    return 100;
}

NSString *IGDashManifestBestAudioURL(NSString *manifest) {
    if (!manifest.length) return nil;

    NSRegularExpression *setRe = [NSRegularExpression regularExpressionWithPattern:@"<AdaptationSet\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray<NSTextCheckingResult *> *setMatches = [setRe matchesInString:manifest options:0 range:NSMakeRange(0, manifest.length)];

    NSInteger bestScore = -1;
    NSUInteger bestBW = 0;
    NSString *bestURL = nil;

    NSRegularExpression *repRe = [NSRegularExpression regularExpressionWithPattern:@"<Representation\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];

    for (NSTextCheckingResult *setMatch in setMatches) {
        NSString *setTag = [manifest substringWithRange:setMatch.range];
        NSString *contentType = [ThetaDashXMLAttr(setTag, @"contentType") lowercaseString];
        NSString *mimeType = [ThetaDashXMLAttr(setTag, @"mimeType") lowercaseString];
        BOOL isAudio = [contentType isEqualToString:@"audio"] || [mimeType hasPrefix:@"audio"];
        if (!isAudio) continue;

        NSRange fromStart = NSMakeRange(setMatch.range.location, manifest.length - setMatch.range.location);
        NSRange close = [manifest rangeOfString:@"</AdaptationSet>" options:0 range:fromStart];
        if (close.location == NSNotFound) continue;

        NSRange blockRange = NSMakeRange(setMatch.range.location, NSMaxRange(close) - setMatch.range.location);
        NSString *block = [manifest substringWithRange:blockRange];
        NSArray<NSTextCheckingResult *> *repMatches = [repRe matchesInString:block options:0 range:NSMakeRange(0, block.length)];
        for (NSTextCheckingResult *rm in repMatches) {
            NSString *tag = [block substringWithRange:rm.range];
            NSString *url = ThetaDashExtractBaseURLAfterRangeInBlock(block, rm.range);
            url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!url.length) continue;
            NSUInteger bw = (NSUInteger)[ThetaDashXMLAttr(tag, @"bandwidth") longLongValue];
            NSInteger score = ThetaDashAudioCompatibilityScore(ThetaDashXMLAttr(tag, @"codecs"));
            if (score > bestScore || (score == bestScore && bw >= bestBW)) {
                bestScore = score;
                bestBW = bw;
                bestURL = url;
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

static BOOL ThetaAVAssetLoadKeys(AVAsset *asset) {
    if (!asset) return NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    NSError *err = nil;
    return [asset statusOfValueForKey:@"tracks" error:&err] == AVKeyValueStatusLoaded;
}

BOOL ThetaExportSessionSetFileType(AVAssetExportSession *session, NSString *fileType) {
    if (!session || !fileType.length) return NO;

    /* Deprecated on iOS 16+ and can be empty before compatibility is determined; an empty list
       means "unknown", not "nothing supported", so only reject on a populated mismatch. */
    NSArray<NSString *> *supported = nil;
    @try {
        supported = session.supportedFileTypes;
    } @catch (__unused NSException *e) {
        supported = nil;
    }
    if (supported.count > 0 && ![supported containsObject:fileType]) {
        NSLog(@"[Theta] export preset cannot write %@ (supports %@)", fileType, supported);
        return NO;
    }

    @try {
        session.outputFileType = fileType;
    } @catch (NSException *e) {
        /* This is the crash from the 441.0.0 / iOS 26.6 report: an unguarded setter raising
           NSInvalidArgumentException out of a background queue and aborting the process. */
        NSLog(@"[Theta] setOutputFileType:%@ raised: %@", fileType, e.reason);
        return NO;
    }
    return YES;
}

static NSString *ThetaRenameAudioByMagic(NSString *path) {
    if (!path.length) return path;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return path;
    NSData *head = [handle readDataOfLength:12];
    [handle closeFile];
    BOOL isMP4 = NO;
    BOOL isADTS = NO;
    if (head.length >= 8) {
        const unsigned char *bytes = head.bytes;
        isMP4 = (bytes[4] == 'f' && bytes[5] == 't' && bytes[6] == 'y' && bytes[7] == 'p');
        isADTS = (bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0);
    }
    NSString *ext = isADTS ? @"aac" : @"m4a";
    if (isMP4) ext = @"m4a";
    NSString *dest = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:ext];
    if ([dest isEqualToString:path]) return path;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dest error:nil];
    NSError *err = nil;
    if ([fm moveItemAtPath:path toPath:dest error:&err]) return dest;
    NSLog(@"ThetaPrepareDashAudioForMerge: rename failed %@", err);
    return path;
}

static NSString *ThetaTranscodeAudioToM4A(AVAsset *asset, NSString *sourcePath) {
    if (!asset || !sourcePath.length) return nil;
    NSString *outPath = [[sourcePath stringByDeletingPathExtension] stringByAppendingString:@"_lc.m4a"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:outPath error:nil];
    AVAssetExportSession *session = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    if (!session) return nil;
    session.outputURL = [NSURL fileURLWithPath:outPath];
    if (!ThetaExportSessionSetFileType(session, AVFileTypeAppleM4A)) return nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    [session exportAsynchronouslyWithCompletionHandler:^{
        ok = (session.status == AVAssetExportSessionStatusCompleted);
        if (!ok) NSLog(@"ThetaPrepareDashAudioForMerge: AAC export failed %@ status %ld", session.error, (long)session.status);
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    NSDictionary *attrs = [fm attributesOfItemAtPath:outPath error:nil];
    if (ok && attrs.fileSize > 0) return outPath;
    [fm removeItemAtPath:outPath error:nil];
    return nil;
}

NSString *ThetaPrepareDashAudioForMerge(NSString *audioPath) {
    if (!audioPath.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:audioPath error:nil];
    if (![fm fileExistsAtPath:audioPath] || attrs.fileSize == 0) return nil;

    NSString *path = ThetaRenameAudioByMagic(audioPath);
    if ([path hasSuffix:@"_lc.m4a"]) return path;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    ThetaAVAssetLoadKeys(asset);

    NSString *transcoded = ThetaTranscodeAudioToM4A(asset, path);
    if (transcoded.length) {
        if (![transcoded isEqualToString:path]) [fm removeItemAtPath:path error:nil];
        NSLog(@"ThetaPrepareDashAudioForMerge: transcoded DASH audio to AAC");
        return transcoded;
    }

    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (track) {
        NSLog(@"ThetaPrepareDashAudioForMerge: using original audio (AAC export unavailable)");
        return path;
    }
    NSLog(@"ThetaPrepareDashAudioForMerge: no decodable audio track in %@", path);
    return nil;
}

static BOOL ThetaExportPhotosCompatibleMP4Impl(NSString *videoPath, NSString *audioPath, BOOL hasAudio, NSString *outputPath);

BOOL ThetaExportPhotosCompatibleMP4(NSString *videoPath, NSString *audioPath, BOOL hasAudio, NSString *outputPath) {
    /* Backstop: AVFoundation raises for parameter problems rather than returning an error, and
       every caller runs on a background queue where an escaping exception aborts the process. */
    @try {
        return ThetaExportPhotosCompatibleMP4Impl(videoPath, audioPath, hasAudio, outputPath);
    } @catch (NSException *e) {
        NSLog(@"[Theta] ThetaExportPhotosCompatibleMP4 raised: %@ — %@", e.name, e.reason);
        return NO;
    }
}

static BOOL ThetaExportPhotosCompatibleMP4Impl(NSString *videoPath, NSString *audioPath, BOOL hasAudio, NSString *outputPath) {
    if (videoPath.length == 0 || outputPath.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];

    AVAsset *videoAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
    ThetaAVAssetLoadKeys(videoAsset);
    AVAssetTrack *videoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) return NO;

    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *compVideo = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTime videoDur = videoAsset.duration;
    if (!CMTIME_IS_NUMERIC(videoDur) || CMTIME_COMPARE_INLINE(videoDur, <=, kCMTimeZero)) return NO;
    NSError *insertErr = nil;
    if (![compVideo insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoDur) ofTrack:videoTrack atTime:kCMTimeZero error:&insertErr]) {
        NSLog(@"ThetaExportPhotosCompatibleMP4: video insert failed %@", insertErr);
        return NO;
    }
    NSString *preparedAudio = nil;
    if (hasAudio && audioPath.length && [fm fileExistsAtPath:audioPath]) {
        preparedAudio = ThetaPrepareDashAudioForMerge(audioPath);
    }
    if (preparedAudio.length) {
        AVAsset *audioAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:preparedAudio] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
        ThetaAVAssetLoadKeys(audioAsset);
        AVAssetTrack *audioTrack = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (audioTrack) {
            AVMutableCompositionTrack *compAudio = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime audioDur = audioAsset.duration;
            CMTime mergeDur = CMTIME_IS_NUMERIC(audioDur) ? CMTimeMinimum(videoDur, audioDur) : videoDur;
            NSError *audioErr = nil;
            if (![compAudio insertTimeRange:CMTimeRangeMake(kCMTimeZero, mergeDur) ofTrack:audioTrack atTime:kCMTimeZero error:&audioErr] || audioErr) {
                NSLog(@"ThetaExportPhotosCompatibleMP4: audio insert failed %@", audioErr);
            }
        } else {
            NSLog(@"ThetaExportPhotosCompatibleMP4: prepared audio has no track");
        }
    }

    NSArray<NSString *> *preferred = @[
        AVAssetExportPresetHighestQuality,
        AVAssetExportPresetHEVCHighestQuality,
        AVAssetExportPreset1920x1080,
        AVAssetExportPreset1280x720,
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetLowQuality,
    ];
    NSArray<NSString *> *compatible = [AVAssetExportSession exportPresetsCompatibleWithAsset:composition] ?: @[];
    NSMutableArray<NSString *> *toTry = [NSMutableArray array];
    for (NSString *preset in preferred) {
        if ([compatible containsObject:preset]) [toTry addObject:preset];
    }
    for (NSString *preset in compatible) {
        if ([preset isEqualToString:AVAssetExportPresetPassthrough]) continue;
        if (![toTry containsObject:preset]) [toTry addObject:preset];
    }

    NSURL *outURL = [NSURL fileURLWithPath:outputPath];
    for (NSString *preset in toTry) {
        if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];
        AVAssetExportSession *session = [AVAssetExportSession exportSessionWithAsset:composition presetName:preset];
        if (!session) continue;
        session.outputURL = outURL;
        if (!ThetaExportSessionSetFileType(session, AVFileTypeMPEG4)) continue;
        if ([session respondsToSelector:@selector(setShouldOptimizeForNetworkUse:)]) {
            session.shouldOptimizeForNetworkUse = YES;
        }
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        [session exportAsynchronouslyWithCompletionHandler:^{
            ok = (session.status == AVAssetExportSessionStatusCompleted);
            if (!ok) NSLog(@"ThetaExportPhotosCompatibleMP4 preset %@ failed: %@ status %ld", preset, session.error, (long)session.status);
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        NSDictionary *attrs = [fm attributesOfItemAtPath:outputPath error:nil];
        if (ok && attrs && [attrs fileSize] > 0) return YES;
        [fm removeItemAtPath:outputPath error:nil];
    }
    return NO;
}

void ThetaPhotoLibraryImportVideoFromURL(NSURL *fileURL, void (^completion)(BOOL success, NSError *error)) {
    if (!fileURL) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ThetaDashManifest" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Missing file URL"}]);
        return;
    }
    void (^finish)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        if (completion) completion(success, error);
    };
    // addResourceWithType accepts more codecs (including AV1 on recent iOS) than
    // creationRequestForAssetFromVideoAtFileURL, which Photos often rejects as invalid.
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
        PHAssetResourceCreationOptions *opts = [PHAssetResourceCreationOptions new];
        opts.shouldMoveFile = NO;
        [req addResourceWithType:PHAssetResourceTypeVideo fileURL:fileURL options:opts];
    } completionHandler:^(BOOL success, NSError *_Nullable error) {
        if (success || !error) {
            finish(success, error);
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
        } completionHandler:^(BOOL retryOK, NSError *_Nullable retryErr) {
            finish(retryOK, retryOK ? nil : (retryErr ?: error));
        }];
    }];
}
