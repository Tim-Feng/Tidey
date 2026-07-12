#import <XCTest/XCTest.h>

#import "iTermController.h"

@interface iTermController (TideyReleaseConfigTests)
+ (NSString *)tideySoftwareUpdateFeedURLWithInfoDictionary:(NSDictionary *)infoDictionary
                                     checkForTestReleases:(BOOL)checkForTestReleases
                                                    shard:(NSInteger)shard;
@end

@interface TideyReleaseConfigTests : XCTestCase
@end

// Repo root derived from this source file so the tests work on any checkout
// location (CI runners check out under /Users/runner/work/...).
static NSString *TideyRepoRootPath(void) {
    return [[[NSString stringWithUTF8String:__FILE__]
             stringByDeletingLastPathComponent]  // iTerm2XCTests/
            stringByDeletingLastPathComponent];  // repo root
}

@implementation TideyReleaseConfigTests

- (void)testSparkleFeedURLUsesTestingFeedAndShard {
    NSDictionary *info = @{
        @"SUFeedURLForTesting": @"https://example.com/testing.xml",
        @"SUFeedURLForFinal": @"https://example.com/final.xml",
    };
    NSString *url = [iTermController tideySoftwareUpdateFeedURLWithInfoDictionary:info
                                                            checkForTestReleases:YES
                                                                           shard:7];
    XCTAssertEqualObjects(url, @"https://example.com/testing.xml?shard=7");
}

- (void)testSparkleFeedURLUsesFinalFeedAndShard {
    NSDictionary *info = @{
        @"SUFeedURLForTesting": @"https://example.com/testing.xml",
        @"SUFeedURLForFinal": @"https://example.com/final.xml",
    };
    NSString *url = [iTermController tideySoftwareUpdateFeedURLWithInfoDictionary:info
                                                            checkForTestReleases:NO
                                                                           shard:3];
    XCTAssertEqualObjects(url, @"https://example.com/final.xml?shard=3");
}

- (void)testDevelopmentAndDeploymentConfigsUseDifferentBundleIdentifiers {
    NSString *pbxprojPath = [TideyRepoRootPath() stringByAppendingPathComponent:@"iTerm2.xcodeproj/project.pbxproj"];
    NSString *contents = [NSString stringWithContentsOfFile:pbxprojPath encoding:NSUTF8StringEncoding error:nil];
    XCTAssertNotNil(contents);
    XCTAssertTrue([contents containsString:@"PRODUCT_BUNDLE_IDENTIFIER = com.tidey.app.dev;"]);
    XCTAssertTrue([contents containsString:@"PRODUCT_BUNDLE_IDENTIFIER = com.tidey.app;"]);
    XCTAssertTrue([contents containsString:@"PRODUCT_NAME = \"Tidey Dev\";"]);
    XCTAssertTrue([contents containsString:@"PRODUCT_NAME = Tidey;"]);
}

- (void)testDevelopmentAndReleasePlistsContainSparkleKeys {
    NSDictionary *devPlist = [NSDictionary dictionaryWithContentsOfFile:
                              [TideyRepoRootPath() stringByAppendingPathComponent:@"plists/dev-iTerm2.plist"]];
    NSDictionary *releasePlist = [NSDictionary dictionaryWithContentsOfFile:
                                  [TideyRepoRootPath() stringByAppendingPathComponent:@"plists/release-iTerm2.plist"]];
    XCTAssertNotNil(devPlist);
    XCTAssertNotNil(releasePlist);
    for (NSDictionary *plist in @[ devPlist, releasePlist ]) {
        XCTAssertNotNil(plist[@"SUFeedURLForTesting"]);
        XCTAssertNotNil(plist[@"SUFeedURLForFinal"]);
        XCTAssertNotNil(plist[@"SUPublicEDKey"]);
    }
}

@end
