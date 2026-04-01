#import <XCTest/XCTest.h>

#import "ITAddressBookMgr.h"
#import "PTYSession.h"
#import "PseudoTerminal.h"
#import "iTermProfilePreferences.h"
#import "iTermSelectorSwizzler.h"
#import "iTermSessionFactory.h"

@interface iTermSessionAttachOrLaunchRequest (TideySessionFactoryLaunchCommandTests)
@property(nonatomic, readonly, copy) NSString *computedCommand;
- (void)computeCommandWithCompletion:(void (^)(void))completion;
@end

@interface TideySessionFactoryLaunchCommandTests : XCTestCase
@end

@implementation TideySessionFactoryLaunchCommandTests

- (void)testComputeCommandWrapsStandardLoginCommandThroughTideyLaunchCommand {
    Profile *profile = @{
        KEY_NAME: @"Default",
        KEY_CUSTOM_COMMAND: kProfilePreferenceCommandTypeLoginShellValue,
        KEY_COMMAND_LINE: @"",
        KEY_CUSTOM_DIRECTORY: kProfilePreferenceInitialDirectoryHomeValue,
    };
    iTermSessionFactory *factory = [[[iTermSessionFactory alloc] init] autorelease];
    PTYSession *session = [[factory newSessionWithProfile:profile parent:nil] autorelease];
    iTermSessionAttachOrLaunchRequest *request =
        [iTermSessionAttachOrLaunchRequest launchRequestWithSession:session
                                                          canPrompt:NO
                                                         objectType:iTermWindowObject
                                                hasServerConnection:NO
                                                   serverConnection:(iTermGeneralServerConnection){}
                                                          urlString:nil
                                                       allowURLSubs:NO
                                                        environment:nil
                                                        customShell:nil
                                                             oldCWD:nil
                                                     forceUseOldCWD:NO
                                                            command:nil
                                                             isUTF8:nil
                                                      substitutions:nil
                                                   windowController:nil
                                                              ready:nil
                                                         completion:nil];

    __block BOOL completionCalled = NO;
    [iTermSelectorSwizzler swizzleSelector:@selector(computeCommandForProfile:objectType:scope:completion:)
                                 fromClass:[ITAddressBookMgr class]
                                 withBlock:^(Class cls,
                                             Profile *swizzledProfile,
                                             iTermObjectType objectType,
                                             id scope,
                                             void (^completion)(NSString *, BOOL)) {
        completion([ITAddressBookMgr standardLoginCommand], NO);
    }
                                  forBlock:^{
        [request computeCommandWithCompletion:^{
            completionCalled = YES;
        }];
    }];

    XCTAssertTrue(completionCalled);
    XCTAssertEqualObjects(request.computedCommand,
                          [ITAddressBookMgr shellLauncherCommandWithCustomShell:nil]);
}

@end
