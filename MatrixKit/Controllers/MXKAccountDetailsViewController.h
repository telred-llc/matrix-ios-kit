/*
Copyright 2015 OpenMarket Ltd

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#import <UIKit/UIKit.h>

#import "MXKTableViewController.h"

#import "MXKAccountManager.h"

/**
 */
typedef void (^blockMXKAccountDetailsViewController_onReadyToLeave)();

/**
 MXKAccountDetailsViewController instance may be used to display/edit the details of a matrix account.
 */
@interface MXKAccountDetailsViewController : MXKTableViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>

/**
 The account displayed into the view controller.
 */
@property (nonatomic) MXKAccount *mxAccount;

@property (nonatomic, readonly) IBOutlet UIButton *userPictureButton;
@property (nonatomic, readonly) IBOutlet UITextField *userDisplayName;
@property (nonatomic, readonly) IBOutlet UIButton *saveUserInfoButton;

@property (nonatomic, readonly) IBOutlet UIView *profileActivityIndicatorBgView;
@property (nonatomic, readonly) IBOutlet UIActivityIndicatorView *profileActivityIndicator;

#pragma mark - Class methods

/**
 Returns the `UINib` object initialized for a `MXKAccountDetailsViewController`.

 @return The initialized `UINib` object or `nil` if there were errors during initialization
 or the nib file could not be located.
 
 @discussion You may override this method to provide a customized nib. If you do,
 you should also override `accountDetailsViewController` to return your
 view controller loaded from your custom nib.
 */
+ (UINib *)nib;

/**
 Creates and returns a new `MXKAccountDetailsViewController` object.

 @discussion This is the designated initializer for programmatic instantiation.
 @return An initialized `MXKAccountDetailsViewController` object if successful, `nil` otherwise.
 */
+ (instancetype)accountDetailsViewController;

/**
 */
- (IBAction)onButtonPressed:(id)sender;

/**
 */
- (BOOL)shouldLeave:(blockMXKAccountDetailsViewController_onReadyToLeave)handler;

@end
