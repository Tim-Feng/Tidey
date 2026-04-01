#import <XCTest/XCTest.h>

#import "ITAddressBookMgr.h"
#import "iTermProfilePreferences.h"

@interface TideyLoginShellCommandTests : XCTestCase
@end

@implementation TideyLoginShellCommandTests

- (Profile *)defaultLoginShellProfile {
    return @{
        KEY_CUSTOM_COMMAND: kProfilePreferenceCommandTypeLoginShellValue,
        KEY_COMMAND_LINE: @"",
        KEY_CUSTOM_DIRECTORY: kProfilePreferenceInitialDirectoryHomeValue,
    };
}

- (Profile *)customShellProfile {
    return @{
        KEY_CUSTOM_COMMAND: kProfilePreferenceCommandTypeCustomShellValue,
        KEY_COMMAND_LINE: @"/bin/zsh",
        KEY_CUSTOM_DIRECTORY: kProfilePreferenceInitialDirectoryHomeValue,
    };
}

- (void)testDefaultLoginShellUsesShellLauncherCommand {
    NSString *command = [ITAddressBookMgr loginShellCommandForBookmark:self.defaultLoginShellProfile
                                                         forObjectType:iTermWindowObject];

    XCTAssertEqualObjects(command, [ITAddressBookMgr shellLauncherCommandWithCustomShell:nil]);
    XCTAssertNotEqualObjects(command, [ITAddressBookMgr standardLoginCommand]);
}

- (void)testCustomShellLoginUsesShellLauncherCommandWithCustomShell {
    NSString *command = [ITAddressBookMgr loginShellCommandForBookmark:self.customShellProfile
                                                         forObjectType:iTermWindowObject];

    XCTAssertEqualObjects(command, [ITAddressBookMgr shellLauncherCommandWithCustomShell:@"/bin/zsh"]);
}

@end
