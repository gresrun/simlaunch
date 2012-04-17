/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2010 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "PLSimulatorDiscovery.h"

@interface PLSimulatorDiscovery (PrivateMethods)
- (void) queryFinished: (NSNotification *) notification;
- (void) xcodeQueryFinished: (NSNotification *) note;
@end

/**
 * Implements automatic discovery of local Simulator Platform SDKs.
 *
 * @par Thread Safety
 * Mutable and may not be shared across threads.
 */
@implementation PLSimulatorDiscovery

@synthesize delegate = _delegate;


- (void)dealloc
{
    _delegate = nil;
    [_version release];
    [_canonicalSDKName release];
    [_deviceFamilies release];
    _query.delegate = nil;
    [_query release];
    [_xcodeQuery release];
    [_xcodeUrls release];
    [super dealloc];
}

/**
 * Initialize a new query with the requested minumum simulator SDK version.
 *
 * @param version The required minumum simulator SDK version (3.0, 3.1.2, 3.2, etc). May be nil, in which
 * case no matching will be done on the version.
 * @param sdkName Specify a canonical name for an SDK that must be included with the platform SDK (iphonesimulator3.1, etc).
 * If nil, no verification of the canonical name will be done on SDKs contained in the platform SDK. 
 * @param deviceFamilies The set of requested PLSimulatorDeviceFamily types. Platform SDKs that match any of these device
 * families will be returned.
 */
- (id) initWithMinimumVersion: (NSString *) version 
             canonicalSDKName: (NSString *) canonicalSDKName
               deviceFamilies: (NSSet *) deviceFamilies 
{
    if ((self = [super init]) == nil)
        return nil;

    _version = [version copy];
    _canonicalSDKName = [canonicalSDKName copy];
    _deviceFamilies = [deviceFamilies copy];
    _query = [NSMetadataQuery new];
    _xcodeQuery = [NSMetadataQuery new];
    
    /* Set up a query for all iPhoneSimulator platform directories. We use kMDItemDisplayName rather than
     * the more correct kMDItemFSName for performance reasons -- */
    [_query setPredicate: [NSPredicate predicateWithFormat: @"kMDItemDisplayName == 'iPhoneSimulator.platform'"]];
    
    /* We want to search the root volume for the developer tools. */

    /* Configure result listening */
    NSNotificationCenter *nf = [NSNotificationCenter defaultCenter];
    [nf addObserver: self 
           selector: @selector(queryFinished:)
               name: NSMetadataQueryDidFinishGatheringNotification 
             object: _query];

    [_query setDelegate: self];

    return self;
}

/**
 * Start the query. A query can't be started if one is already running.
 */
- (void) startPlatformQuery {
    assert(_running == NO);
    _running = YES;
    
    NSURL *root = [NSURL fileURLWithPath: @"/" isDirectory: YES];
    NSMutableArray *scopes = [NSMutableArray array];
    [scopes addObject:root];
    if([_xcodeUrls count] > 0) {
        [scopes addObjectsFromArray:_xcodeUrls];
    }
    [_query setSearchScopes:scopes];
    [_query startQuery];
}

- (void)startQuery {
    /* We want to search the root volume for the developer tools. */
    NSURL *root = [NSURL fileURLWithPath: @"/" isDirectory:YES];
    [_xcodeQuery setSearchScopes:[NSArray arrayWithObject:root]];
    [_xcodeQuery setPredicate:[NSPredicate predicateWithFormat: @"kMDItemCFBundleIdentifier ='com.apple.dt.Xcode'"]];
    NSNotificationCenter *nf = [NSNotificationCenter defaultCenter];
    [nf addObserver: self 
           selector: @selector(xcodeQueryFinished:)
               name: NSMetadataQueryDidFinishGatheringNotification 
             object: _xcodeQuery];
    [_xcodeQuery setDelegate: self];
    //todo: set a timer that will time out and invalidate itself then call start platform query. 
    [_xcodeQuery startQuery];
}

@end

/**
 * @internal
 */
@implementation PLSimulatorDiscovery (PrivateMethods)

/**
 * Comparison function. Compared two platforms by the latest version of their sub-SDKs.
 * Used to determine which platform is likely the most stable, as most users will only
 * have two SDKs installed -- the current, and a beta SDK.
 */
static NSInteger platform_compare_by_version (id obj1, id obj2, void *context) {
    PLSimulatorPlatform *platform1 = obj1;
    PLSimulatorPlatform *platform2 = obj2;
    
    /* Fetch the highest SDK version for each platform */
    NSString *(^Version)(PLSimulatorPlatform *) = ^(PLSimulatorPlatform *p) {
        NSString *last = nil;
        for (PLSimulatorSDK *sdk in p.sdks) {
            if (last == nil || rpm_vercomp([sdk.version UTF8String], [last UTF8String]) > 0)
                last = sdk.version;
        }

        return last;
    };
    
    NSString *ver1 = Version(platform1);
    NSString *ver2 = Version(platform2);

    /* Neither should be nil as we shouldn't be called on Platform SDKs that do not
     * contain sub-SDKs, but if that occurs, provide a reasonable answer */
    if (ver1 == nil && ver2 == nil)
        return NSOrderedSame;
    else if (ver1 == nil)
        return NSOrderedAscending;
    else if (ver2 == nil)
        return NSOrderedDescending;

    int res = rpm_vercomp([ver1 UTF8String], [ver2 UTF8String]);

    if (res > 0)
        return NSOrderedDescending;
    if (res < 0)
        return NSOrderedAscending;
    else
        return NSOrderedSame;
}

// NSMetadataQueryDidFinishGatheringNotification
- (void) queryFinished: (NSNotification *) note {
    /* Received the full spotlight query result set. No longer running */
    _running = NO;
    
    /* Convert the items into PLSimulatorPlatform instances, filtering out results that don't match the minimum version
     * and supported device families. */
    NSArray *results = [_query results];
    [_query stopQuery];
    NSMutableArray *platformSDKs = [NSMutableArray arrayWithCapacity: [results count]];
    
    // A way to test this is to add the Xcode.app/Contents folder to the spotlight privacy list
    //metadata query didn't come back with anything (happens when platform is inside xcode4.3.app
    if([results count] == 0)
    {
        for (NSURL *xcode_contents in _xcodeUrls) {
            if ([[xcode_contents absoluteString] hasSuffix:@"Contents"]) 
            {
                NSError *err = nil;
                NSString *simPlat = [[xcode_contents absoluteString] stringByAppendingPathComponent:@"Developer/Platforms/iPhoneSimulator.platform"];
                NSLog(@"%@", simPlat);
                PLSimulatorPlatform *simPlatform = [[PLSimulatorPlatform alloc] initWithPath:simPlat error:&err]; 
                if (err) NSLog(@"%@", err);
                if (simPlatform) {
                    [platformSDKs addObject:simPlatform];
                }
                [simPlatform release];
            }
        }
    }
    
    for (NSMetadataItem *item in results) {
        PLSimulatorPlatform *platform;
        NSString *path;
        NSError *error;

        path = [[item valueForAttribute: (NSString *) kMDItemPath] stringByResolvingSymlinksInPath];
        platform = [[PLSimulatorPlatform alloc] initWithPath: path error: &error];
        if (platform == nil) {
            NSLog(@"Skipping platform discovery result '%@', failed to load platform SDK meta-data: %@", path, error);
            continue;
        }

        /* Check the minimum version and device families */
        BOOL hasMinVersion = NO;
        BOOL hasDeviceFamily = NO;
        BOOL hasExpectedSDK = NO;

        /* Skip filters that are not required */
        if (_version == nil)
            hasMinVersion = YES;
    
        if (_canonicalSDKName == nil)
            hasExpectedSDK = YES;

        for (PLSimulatorSDK *sdk in platform.sdks) {
            /* If greater than or equal to the minimum version, this platform SDK meets the requirements */
            if (_version != nil && rpm_vercomp([sdk.version UTF8String], [_version UTF8String]) >= 0)
                hasMinVersion = YES;
            
            /* Also check for the canonical SDK name */
            if (_canonicalSDKName != nil && [_canonicalSDKName isEqualToString: sdk.canonicalName])
                hasExpectedSDK = YES;

            /* If any our requested families are included, this platform SDK meets the requirements. */
            for (NSString *family in _deviceFamilies) {
                if ([sdk.deviceFamilies containsObject: family]) {
                    hasDeviceFamily = YES;
                    continue;
                }
            }
        }

        if (!hasMinVersion || !hasDeviceFamily)// || !hasExpectedSDK)
            continue;

        NSLog(@"Found Platform: %@", platform);
        [platformSDKs addObject: platform];
    }

    /* Sort by version, try to choose the most stable SDK of the available set. */
    NSArray *sorted = [platformSDKs sortedArrayUsingFunction: platform_compare_by_version context: nil];
    
    /* Inform the delegate */
    [_delegate simulatorDiscovery: self didFindMatchingSimulatorPlatforms: sorted];
}



- (void) xcodeQueryFinished: (NSNotification *) note {
    NSArray *results = [_xcodeQuery results];
    [_xcodeQuery stopQuery];
    _xcodeQuery.delegate = nil;
    NSMutableArray *xcodeUrls = [NSMutableArray array];
    if ([results count] == 0)
    {
        return;
    }
    for (NSMetadataItem *item in results)
    {
        NSURL *itemUrl = [NSURL URLWithString:[[item valueForAttribute:(NSString *)kMDItemPath] stringByAppendingPathComponent:@"Contents"]];
        [xcodeUrls addObject:itemUrl];
    }
    _xcodeUrls = [xcodeUrls copy];
    if (!_running) {
        [self startPlatformQuery];
    }
}

@end