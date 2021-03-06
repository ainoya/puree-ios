//
//  PURLogger.m
//  Puree
//
//  Created by tomohiro-moro on 10/7/14.
//  Copyright (c) 2014 Tomohiro Moro. All rights reserved.
//

#import "PURLogger.h"
#import "PURLoggerConfiguration.h"
#import "PURTagCheckingResult.h"
#import "PURLogStore.h"
#import "PURLog.h"

#import "PURFilterSetting.h"
#import "PURFilter.h"

#import "PUROutputSetting.h"
#import "PUROutput.h"

@interface PURLogger ()

@property (nonatomic) PURLoggerConfiguration *configuration;
@property (nonatomic) PURFilter *defaultFilter;
@property (nonatomic) NSDictionary *filters;
@property (nonatomic) NSDictionary *filterReactionTagPatterns;
@property (nonatomic) NSDictionary *outputs;
@property (nonatomic) NSDictionary *outputReactionTagPatterns;

@end

@implementation PURLogger

+ (PURTagCheckingResult *)matchesTag:(NSString *)tag pattern:(NSString *)pattern
{
    if ([tag isEqualToString:pattern]) {
        return [PURTagCheckingResult successResult];
    }

    NSString *elementsSeparator = @".";
    NSString *wildcard = @"*";
    NSString *allWildcard = @"**";

    NSArray *patternElements = [pattern componentsSeparatedByString:elementsSeparator];
    NSArray *tagElements = [tag componentsSeparatedByString:elementsSeparator];
    NSString *lastPatternElement = [patternElements lastObject];

    if ([lastPatternElement isEqualToString:allWildcard]) {
        __block BOOL matched = YES;
        [patternElements enumerateObjectsUsingBlock:^(NSString *patternElement, NSUInteger idx, BOOL *stop){
            if (idx == [patternElements count] - 1) {
                return;
            }

            NSString *tagElement = tagElements[idx];
            if (![tagElement isEqualToString:patternElement]) {
                matched = NO;
                *stop = YES;
            }
        }];

        if (matched) {
            NSInteger location = [patternElements count] - 1;
            NSInteger capturedLength = [tagElements count] - location;
            NSString *capturedString = @"";
            if (capturedLength > 0) {
                capturedString = [[tagElements subarrayWithRange:NSMakeRange(location, capturedLength)] componentsJoinedByString:elementsSeparator];
            }
            return [PURTagCheckingResult successResultWithCapturedString:capturedString];
        }
    } else if ([lastPatternElement isEqualToString:wildcard]) {
        if ([tagElements count] == [patternElements count]) {
            __block BOOL matched = YES;
            [patternElements enumerateObjectsUsingBlock:^(NSString *patternElement, NSUInteger idx, BOOL *stop){
                if (idx == [patternElements count] - 1) {
                    return;
                }

                NSString *tagElement = tagElements[idx];
                if (![tagElement isEqualToString:patternElement]) {
                    matched = NO;
                    *stop = YES;
                }
            }];

            if (matched) {
                return [PURTagCheckingResult successResultWithCapturedString:[tagElements lastObject]];
            }
        }
    }

    return [PURTagCheckingResult failureResult];
}

- (instancetype)init
{
    return nil;
}

- (instancetype)initWithConfiguration:(PURLoggerConfiguration *)configuration
{
    self = [super init];
    if (self) {
        _configuration = configuration;

        [self configure];
        [self startPlugins];
    }
    return self;
}

- (void)dealloc
{
    [self shutdown];
}

- (PURLogStore *)logStore
{
    return self.configuration.logStore;
}

- (NSDate *)currentDate
{
    return [NSDate date];
}

- (void)configure
{
    PURLogStore *logStore = self.configuration.logStore;
    [logStore prepare];

    [self configureFilterPlugins];
    [self configureOutputPlugins];

    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self
                           selector:@selector(applicationDidEnterBackground:)
                               name:UIApplicationDidEnterBackgroundNotification
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(applicationWillEnterForeground:)
                               name:UIApplicationWillEnterForegroundNotification
                             object:nil];
}

- (void)configureFilterPlugins
{
    self.defaultFilter = [[PURFilter alloc] initWithLogger:self tagPattern:nil];

    NSMutableDictionary *filters = [NSMutableDictionary new];
    NSMutableDictionary *filterReactionTagPatterns = [NSMutableDictionary new];
    for (PURFilterSetting *setting in self.configuration.filterSettings) {
        if (![setting isKindOfClass:[PURFilterSetting class]]) {
            continue;
        }

        PURFilter *filter = [[setting.filterClass alloc] initWithLogger:self tagPattern:setting.tagPattern];
        if (![filter isKindOfClass:[PURFilter class]]) {
            continue;
        }

        [filter configure:setting.settings];
        filters[filter.identifier] = filter;
        filterReactionTagPatterns[filter.identifier] = setting.tagPattern;
    }
    self.filters = filters;
    self.filterReactionTagPatterns = filterReactionTagPatterns;
}

- (void)configureOutputPlugins
{
    NSMutableDictionary *outputs = [NSMutableDictionary new];
    NSMutableDictionary *outputReactionTagPatterns = [NSMutableDictionary new];
    for (PUROutputSetting *setting in self.configuration.outputSettings) {
        if (![setting isKindOfClass:[PUROutputSetting class]]) {
            continue;
        }

        PUROutput *output = [[setting.outputClass alloc] initWithLogger:self tagPattern:setting.tagPattern];
        if (![output isKindOfClass:[PUROutput class]]) {
            continue;
        }

        [output configure:setting.settings];
        outputs[output.identifier] = output;
        outputReactionTagPatterns[output.identifier] = setting.tagPattern;
    }
    self.outputs = outputs;
    self.outputReactionTagPatterns = outputReactionTagPatterns;
}

- (void)startPlugins
{
    for (PUROutput *output in [self.outputs allValues]) {
        [output start];
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    for (PUROutput *output in [self.outputs allValues]) {
        [output suspend];
    }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    for (PUROutput *output in [self.outputs allValues]) {
        [output resume];
    }
}

- (NSArray *)filteredLogsWithObject:(id)object tag:(NSString *)tag
{
    NSMutableArray *logs = [NSMutableArray new];

    for (NSString *identifier in self.filterReactionTagPatterns) {
        NSString *pattern = self.filterReactionTagPatterns[identifier];
        PURTagCheckingResult *result = [PURLogger matchesTag:tag pattern:pattern];

        if (!result.matched) {
            continue;
        }

        PURFilter *filter = self.filters[identifier];
        NSArray *filteredLogs = [filter logsWithObject:object tag:tag captured:result.capturedString];
        [logs addObjectsFromArray:filteredLogs];
    }

    if ([logs count] == 0) {
        return [self.defaultFilter logsWithObject:object tag:tag captured:nil];
    }
    return logs;
}

- (void)postLog:(id)object tag:(NSString *)sourceTag
{
    for (PURLog *log in [self filteredLogsWithObject:object tag:sourceTag]) {
        NSSet *reactionOutputIdentifiers = [self.outputReactionTagPatterns keysOfEntriesPassingTest:^BOOL(NSString *identifier, NSString *pattern, BOOL *stop){
            return [PURLogger matchesTag:log.tag pattern:pattern].matched;
        }];

        for (NSString *identifier in reactionOutputIdentifiers) {
            PUROutput *output = self.outputs[identifier];
            [output emitLog:log];
        }
    }
}

- (void)shutdown
{
    self.filters = nil;
    self.filterReactionTagPatterns = nil;

    for (PUROutput *output in [self.outputs allValues]) {
        [output suspend];
    }
    self.outputs = nil;
    self.outputReactionTagPatterns = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
