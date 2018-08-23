/*
 Copyright 2015 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd
 Copyright 2018 New Vector Ltd
 
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

#import "MXKRoomMemberDetailsViewController.h"

#import "MXKTableViewCellWithButtons.h"

#import "MXMediaManager.h"

#import "NSBundle+MatrixKit.h"

#import "MXKAppSettings.h"

#import "MXKConstants.h"

@interface MXKRoomMemberDetailsViewController ()
{
    id membersListener;
    
    // mask view while processing a request
    UIActivityIndicatorView * pendingMaskSpinnerView;
    
    // Observe left rooms
    id leaveRoomNotificationObserver;
    
    // Observe kMXRoomDidFlushDataNotification to take into account the updated room members when the room history is flushed.
    id roomDidFlushDataNotificationObserver;

    // Cache for the room live timeline
    MXEventTimeline *mxRoomLiveTimeline;
}

@end

@implementation MXKRoomMemberDetailsViewController
@synthesize mxRoom;

+ (UINib *)nib
{
    return [UINib nibWithNibName:NSStringFromClass([MXKRoomMemberDetailsViewController class])
                          bundle:[NSBundle bundleForClass:[MXKRoomMemberDetailsViewController class]]];
}

+ (instancetype)roomMemberDetailsViewController
{
    return [[[self class] alloc] initWithNibName:NSStringFromClass([MXKRoomMemberDetailsViewController class])
                                          bundle:[NSBundle bundleForClass:[MXKRoomMemberDetailsViewController class]]];
}

- (void)finalizeInit
{
    [super finalizeInit];
    
    actionsArray = [[NSMutableArray alloc] init];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Check whether the view controller has been pushed via storyboard
    if (!self.tableView)
    {
        // Instantiate view controller objects
        [[[self class] nib] instantiateWithOwner:self options:nil];
    }
    
    // ignore useless update
    if (_mxRoomMember)
    {
        [self initObservers];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self initObservers];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [self removeObservers];
}

- (void)destroy
{
    // close any pending actionsheet
    if (currentAlert)
    {
        [currentAlert dismissViewControllerAnimated:NO completion:nil];
        currentAlert = nil;
    }
    
    [self removePendingActionMask];
    
    [self removeObservers];
    
    _delegate = nil;
    _mxRoomMember = nil;
    
    actionsArray = nil;
    
    [super destroy];
}

#pragma mark -

- (void)displayRoomMember:(MXRoomMember*)roomMember withMatrixRoom:(MXRoom*)room
{
    [self removeObservers];
    
    mxRoom = room;

    MXWeakify(self);
    [mxRoom liveTimeline:^(MXEventTimeline *liveTimeline) {
        MXStrongifyAndReturnIfNil(self);

        self->mxRoomLiveTimeline = liveTimeline;

        // Update matrix session associated to the view controller
        NSArray *mxSessions = self.mxSessions;
        for (MXSession *mxSession in mxSessions) {
            [self removeMatrixSession:mxSession];
        }
        [self addMatrixSession:room.mxSession];

        self->_mxRoomMember = roomMember;

        [self initObservers];
    }];
}

- (MXEventTimeline *)mxRoomLiveTimeline
{
    // @TODO(async-state): Just here for dev
    NSAssert(mxRoomLiveTimeline, @"[MXKRoomMemberDetailsViewController] Room live timeline must be preloaded before accessing to MXKRoomMemberDetailsViewController.mxRoomLiveTimeline");
    return mxRoomLiveTimeline;
}

- (UIImage*)picturePlaceholder
{
    return [NSBundle mxk_imageFromMXKAssetsBundleWithName:@"default-profile"];
}

- (void)setEnableMention:(BOOL)enableMention
{
    if (_enableMention != enableMention)
    {
        _enableMention = enableMention;
        
        [self updateMemberInfo];
    }
}

- (void)setEnableVoipCall:(BOOL)enableVoipCall
{
    if (_enableVoipCall != enableVoipCall)
    {
        _enableVoipCall = enableVoipCall;
        
        [self updateMemberInfo];
    }
}

- (IBAction)onActionButtonPressed:(id)sender
{
    if ([sender isKindOfClass:[UIButton class]])
    {
        // Check whether an action is already in progress
        if ([self hasPendingAction])
        {
            return;
        }
        
        UIButton *button = (UIButton*)sender;
        
        switch (button.tag)
        {
            case MXKRoomMemberDetailsActionInvite:
            {
                [self addPendingActionMask];
                [mxRoom inviteUser:_mxRoomMember.userId
                           success:^{
                               
                               [self removePendingActionMask];
                               
                           } failure:^(NSError *error) {
                               
                               [self removePendingActionMask];
                               NSLog(@"[MXKRoomMemberDetailsVC] Invite %@ failed", _mxRoomMember.userId);
                               // Notify MatrixKit user
                               NSString *myUserId = self.mainSession.myUser.userId;
                               [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                               
                           }];
                break;
            }
            case MXKRoomMemberDetailsActionLeave:
            {
                [self addPendingActionMask];
                [self.mxRoom leave:^{
                    
                    [self removePendingActionMask];
                    [self withdrawViewControllerAnimated:YES completion:nil];
                    
                } failure:^(NSError *error) {
                    
                    [self removePendingActionMask];
                    NSLog(@"[MXKRoomMemberDetailsVC] Leave room %@ failed", mxRoom.roomId);
                    // Notify MatrixKit user
                    NSString *myUserId = self.mainSession.myUser.userId;
                    [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                    
                }];
                break;
            }
            case MXKRoomMemberDetailsActionKick:
            {
                [self addPendingActionMask];
                [mxRoom kickUser:_mxRoomMember.userId
                          reason:nil
                         success:^{
                             
                             [self removePendingActionMask];
                             // Pop/Dismiss the current view controller if the left members are hidden
                             if (![[MXKAppSettings standardAppSettings] showLeftMembersInRoomMemberList])
                             {
                                 [self withdrawViewControllerAnimated:YES completion:nil];
                             }
                             
                         } failure:^(NSError *error) {
                             
                             [self removePendingActionMask];
                             NSLog(@"[MXKRoomMemberDetailsVC] Kick %@ failed", _mxRoomMember.userId);
                             // Notify MatrixKit user
                             NSString *myUserId = self.mainSession.myUser.userId;
                             [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                             
                         }];
                break;
            }
            case MXKRoomMemberDetailsActionBan:
            {
                [self addPendingActionMask];
                [mxRoom banUser:_mxRoomMember.userId
                         reason:nil
                        success:^{
                            
                            [self removePendingActionMask];
                            
                        } failure:^(NSError *error) {
                            
                            [self removePendingActionMask];
                            NSLog(@"[MXKRoomMemberDetailsVC] Ban %@ failed", _mxRoomMember.userId);
                            // Notify MatrixKit user
                            NSString *myUserId = self.mainSession.myUser.userId;
                            [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                            
                        }];
                break;
            }
            case MXKRoomMemberDetailsActionUnban:
            {
                [self addPendingActionMask];
                [mxRoom unbanUser:_mxRoomMember.userId
                          success:^{
                              
                              [self removePendingActionMask];
                              
                          } failure:^(NSError *error) {
                              
                              [self removePendingActionMask];
                              NSLog(@"[MXKRoomMemberDetailsVC] Unban %@ failed", _mxRoomMember.userId);
                              // Notify MatrixKit user
                              NSString *myUserId = self.mainSession.myUser.userId;
                              [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                              
                          }];
                break;
            }
            case MXKRoomMemberDetailsActionIgnore:
            {
                // Prompt user to ignore content from this user
                __weak __typeof(self) weakSelf = self;
                if (currentAlert)
                {
                    [currentAlert dismissViewControllerAnimated:NO completion:nil];
                }
                
                currentAlert = [UIAlertController alertControllerWithTitle:[NSBundle mxk_localizedStringForKey:@"room_member_ignore_prompt"] message:nil preferredStyle:UIAlertControllerStyleAlert];
                
                [currentAlert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"yes"]
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^(UIAlertAction * action) {
                                                                   
                                                                   if (weakSelf)
                                                                   {
                                                                       typeof(self) self = weakSelf;
                                                                       self->currentAlert = nil;
                                                                       
                                                                       // Add the user to the blacklist: ignored users
                                                                       [self addPendingActionMask];
                                                                       [self.mainSession ignoreUsers:@[self.mxRoomMember.userId]
                                                                                             success:^{
                                                                                                 
                                                                                                 [self removePendingActionMask];
                                                                                                 
                                                                                             } failure:^(NSError *error) {
                                                                                                 
                                                                                                 [self removePendingActionMask];
                                                                                                 NSLog(@"[MXKRoomMemberDetailsVC] Ignore %@ failed", self.mxRoomMember.userId);
                                                                                                 
                                                                                                 // Notify MatrixKit user
                                                                                                 NSString *myUserId = self.mainSession.myUser.userId;
                                                                                                 [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                                                                                                 
                                                                                             }];
                                                                   }
                                                                   
                                                               }]];
                
                [currentAlert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"no"]
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^(UIAlertAction * action) {
                                                                   
                                                                   if (weakSelf)
                                                                   {
                                                                       typeof(self) self = weakSelf;
                                                                       self->currentAlert = nil;
                                                                   }
                                                                   
                                                               }]];
                
                [self presentViewController:currentAlert animated:YES completion:nil];
                break;
            }
            case MXKRoomMemberDetailsActionUnignore:
            {
                // Remove the member from the ignored user list.
                [self addPendingActionMask];
                __weak __typeof(self) weakSelf = self;
                [self.mainSession unIgnoreUsers:@[self.mxRoomMember.userId]
                                            success:^{

                                                __strong __typeof(weakSelf)strongSelf = weakSelf;
                                                [strongSelf removePendingActionMask];

                                            } failure:^(NSError *error) {

                                                __strong __typeof(weakSelf)strongSelf = weakSelf;
                                                [strongSelf removePendingActionMask];
                                                NSLog(@"[MXKRoomMemberDetailsVC] Unignore %@ failed", strongSelf.mxRoomMember.userId);

                                                // Notify MatrixKit user
                                                NSString *myUserId = self.mainSession.myUser.userId;
                                                [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];

                                            }];
                break;
            }
            case MXKRoomMemberDetailsActionSetDefaultPowerLevel:
            {
                break;
            }
            case MXKRoomMemberDetailsActionSetModerator:
            {
                break;
            }
            case MXKRoomMemberDetailsActionSetAdmin:
            {
                break;
            }
            case MXKRoomMemberDetailsActionSetCustomPowerLevel:
            {
                [self updateUserPowerLevel];
                break;
            }
            case MXKRoomMemberDetailsActionStartChat:
            {
                if (self.delegate)
                {
                    [self addPendingActionMask];
                    
                    [self.delegate roomMemberDetailsViewController:self startChatWithMemberId:_mxRoomMember.userId completion:^{
                        
                        [self removePendingActionMask];
                    }];
                }
                break;
            }
            case MXKRoomMemberDetailsActionStartVoiceCall:
            case MXKRoomMemberDetailsActionStartVideoCall:
            {
                BOOL isVideoCall = (button.tag == MXKRoomMemberDetailsActionStartVideoCall);
                
                if (self.delegate && [self.delegate respondsToSelector:@selector(roomMemberDetailsViewController:placeVoipCallWithMemberId:andVideo:)])
                {
                    [self addPendingActionMask];
                    
                    [self.delegate roomMemberDetailsViewController:self placeVoipCallWithMemberId:_mxRoomMember.userId andVideo:isVideoCall];
                    
                    [self removePendingActionMask];
                }
                else
                {
                    [self addPendingActionMask];
                    
                    MXRoom* directRoom = [self.mainSession directJoinedRoomWithUserId:_mxRoomMember.userId];
                    
                    // Place the call directly if the room exists
                    if (directRoom)
                    {
                        [directRoom placeCallWithVideo:isVideoCall success:nil failure:nil];
                        [self removePendingActionMask];
                    }
                    else
                    {
                        // Create a new room
                        [self.mainSession createRoom:nil
                                          visibility:kMXRoomDirectoryVisibilityPrivate
                                           roomAlias:nil
                                               topic:nil
                                              invite:@[_mxRoomMember.userId]
                                          invite3PID:nil
                                            isDirect:YES
                                              preset:kMXRoomPresetTrustedPrivateChat
                                             success:^(MXRoom *room) {
                                                 
                                                 // Delay the call in order to be sure that the room is ready
                                                 dispatch_async(dispatch_get_main_queue(), ^{
                                                     [room placeCallWithVideo:isVideoCall success:nil failure:nil];
                                                     [self removePendingActionMask];
                                                 });
                                                 
                                             } failure:^(NSError *error) {
                                                 
                                                 NSLog(@"[MXKRoomMemberDetailsVC] Create room failed");
                                                 [self removePendingActionMask];
                                                 // Notify MatrixKit user
                                                 NSString *myUserId = self.mainSession.myUser.userId;
                                                 [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                                                 
                                             }];
                    }
                }
                break;
            }
            case MXKRoomMemberDetailsActionMention:
            {
                // Sanity check
                if (_delegate && [_delegate respondsToSelector:@selector(roomMemberDetailsViewController:mention:)])
                {
                    id<MXKRoomMemberDetailsViewControllerDelegate> delegate = _delegate;
                    MXRoomMember *member = _mxRoomMember;
                    
                    // Withdraw the current view controller, and let the delegate mention the member
                    [self withdrawViewControllerAnimated:YES completion:^{
                        
                        [delegate roomMemberDetailsViewController:self mention:member];

                    }];
                }
                break;
            }
            default:
                break;
        }
    }
}

#pragma mark - Internals

- (void)initObservers
{
    // Remove any pending observers
    [self removeObservers];
    
    if (mxRoom)
    {
        // Observe room's members update
        NSArray *mxMembersEvents = @[kMXEventTypeStringRoomMember, kMXEventTypeStringRoomPowerLevels];
        self->membersListener = [mxRoom listenToEventsOfTypes:mxMembersEvents onEvent:^(MXEvent *event, MXTimelineDirection direction, id customObject) {

            // consider only live event
            if (direction == MXTimelineDirectionForwards)
            {
                [self refreshRoomMember];
            }
        }];

        // Observe kMXSessionWillLeaveRoomNotification to be notified if the user leaves the current room.
        leaveRoomNotificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kMXSessionWillLeaveRoomNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
            
            // Check whether the user will leave the room related to the displayed member
            if (notif.object == self.mainSession)
            {
                NSString *roomId = notif.userInfo[kMXSessionNotificationRoomIdKey];
                if (roomId && [roomId isEqualToString:mxRoom.roomId])
                {
                    // We must remove the current view controller.
                    [self withdrawViewControllerAnimated:YES completion:nil];
                }
            }
        }];
        
        // Observe room history flush (sync with limited timeline, or state event redaction)
        roomDidFlushDataNotificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kMXRoomDidFlushDataNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
            
            MXRoom *room = notif.object;
            if (self.mainSession == room.mxSession && [mxRoom.roomId isEqualToString:room.roomId])
            {
                // The existing room history has been flushed during server sync.
                // Take into account the updated room members list by updating the room member instance
                [self refreshRoomMember];
            }
            
        }];
    }
    
    [self updateMemberInfo];
}

- (void)removeObservers
{
    if (leaveRoomNotificationObserver)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:leaveRoomNotificationObserver];
        leaveRoomNotificationObserver = nil;
    }
    if (roomDidFlushDataNotificationObserver)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:roomDidFlushDataNotificationObserver];
        roomDidFlushDataNotificationObserver = nil;
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (membersListener && mxRoom)
    {
        MXWeakify(self);
        [mxRoom liveTimeline:^(MXEventTimeline *liveTimeline) {
            MXStrongifyAndReturnIfNil(self);

            [liveTimeline removeListener:self->membersListener];
            self->membersListener = nil;
        }];
    }
}

- (void)refreshRoomMember
{
    // Hide potential action sheet
    if (currentAlert)
    {
        [currentAlert dismissViewControllerAnimated:NO completion:nil];
        currentAlert = nil;
    }
    
    MXRoomMember* nextRoomMember = nil;
    
    // get the updated memmber
    NSArray<MXRoomMember *> *membersList = self.mxRoomLiveTimeline.state.members.members;
    for (MXRoomMember* member in membersList)
    {
        if ([member.userId isEqualToString:_mxRoomMember.userId])
        {
            nextRoomMember = member;
            break;
        }
    }
    
    // does the member still exist ?
    if (nextRoomMember)
    {
        // Refresh member
        _mxRoomMember = nextRoomMember;
        [self updateMemberInfo];
    }
    else
    {
        [self withdrawViewControllerAnimated:YES completion:nil];
    }
}

- (void)updateMemberInfo
{
    self.title = _mxRoomMember.displayname ? _mxRoomMember.displayname : _mxRoomMember.userId;
    
    // set the thumbnail info
    self.memberThumbnail.contentMode = UIViewContentModeScaleAspectFill;
    self.memberThumbnail.defaultBackgroundColor = [UIColor clearColor];
    [self.memberThumbnail.layer setCornerRadius:self.memberThumbnail.frame.size.width / 2];
    [self.memberThumbnail setClipsToBounds:YES];
    
    NSString *thumbnailURL = nil;
    if (_mxRoomMember.avatarUrl)
    {
        // Suppose this url is a matrix content uri, we use SDK to get the well adapted thumbnail from server
        thumbnailURL = [self.mainSession.matrixRestClient urlOfContentThumbnail:_mxRoomMember.avatarUrl toFitViewSize:self.memberThumbnail.frame.size withMethod:MXThumbnailingMethodCrop];
    }
    
    self.memberThumbnail.mediaFolder = kMXMediaManagerAvatarThumbnailFolder;
    self.memberThumbnail.enableInMemoryCache = YES;
    [self.memberThumbnail setImageURL:thumbnailURL withType:nil andImageOrientation:UIImageOrientationUp previewImage:self.picturePlaceholder];
    
    self.roomMemberMatrixInfo.text = _mxRoomMember.userId;
    
    [self.tableView reloadData];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // Check user's power level before allowing an action (kick, ban, ...)
    MXRoomPowerLevels *powerLevels = [self.mxRoomLiveTimeline.state powerLevels];
    NSInteger memberPowerLevel = [powerLevels powerLevelOfUserWithUserID:_mxRoomMember.userId];
    NSInteger oneSelfPowerLevel = [powerLevels powerLevelOfUserWithUserID:self.mainSession.myUser.userId];
    
    [actionsArray removeAllObjects];
    
    // Consider the case of the user himself
    if ([_mxRoomMember.userId isEqualToString:self.mainSession.myUser.userId])
    {
        [actionsArray addObject:@(MXKRoomMemberDetailsActionLeave)];
        
        if (oneSelfPowerLevel >= [powerLevels minimumPowerLevelForSendingEventAsStateEvent:kMXEventTypeStringRoomPowerLevels])
        {
            [actionsArray addObject:@(MXKRoomMemberDetailsActionSetCustomPowerLevel)];
        }
    }
    else if (_mxRoomMember)
    {
        if (_enableVoipCall)
        {
            // Offer voip call options
            [actionsArray addObject:@(MXKRoomMemberDetailsActionStartVoiceCall)];
            [actionsArray addObject:@(MXKRoomMemberDetailsActionStartVideoCall)];
        }
        
        // Consider membership of the selected member
        switch (_mxRoomMember.membership)
        {
            case MXMembershipInvite:
            case MXMembershipJoin:
            {
                // Check conditions to be able to kick someone
                if (oneSelfPowerLevel >= [powerLevels kick] && oneSelfPowerLevel > memberPowerLevel)
                {
                    [actionsArray addObject:@(MXKRoomMemberDetailsActionKick)];
                }
                // Check conditions to be able to ban someone
                if (oneSelfPowerLevel >= [powerLevels ban] && oneSelfPowerLevel > memberPowerLevel)
                {
                    [actionsArray addObject:@(MXKRoomMemberDetailsActionBan)];
                }
                
                // Check whether the option Ignore may be presented
                if (_mxRoomMember.membership == MXMembershipJoin)
                {
                    // is he already ignored ?
                    if (![self.mainSession isUserIgnored:_mxRoomMember.userId])
                    {
                        [actionsArray addObject:@(MXKRoomMemberDetailsActionIgnore)];
                    }
                    else
                    {
                        [actionsArray addObject:@(MXKRoomMemberDetailsActionUnignore)];
                    }
                }
                break;
            }
            case MXMembershipLeave:
            {
                // Check conditions to be able to invite someone
                if (oneSelfPowerLevel >= [powerLevels invite])
                {
                    [actionsArray addObject:@(MXKRoomMemberDetailsActionInvite)];
                }
                // Check conditions to be able to ban someone
                if (oneSelfPowerLevel >= [powerLevels ban] && oneSelfPowerLevel > memberPowerLevel)
                {
                    [actionsArray addObject:@(MXKRoomMemberDetailsActionBan)];
                }
                break;
            }
            case MXMembershipBan:
            {
                // Check conditions to be able to unban someone
                if (oneSelfPowerLevel >= [powerLevels ban] && oneSelfPowerLevel > memberPowerLevel)
                {
                    [actionsArray addObject:@(MXKRoomMemberDetailsActionUnban)];
                }
                break;
            }
            default:
            {
                break;
            }
        }
        
        // update power level
        if (oneSelfPowerLevel >= [powerLevels minimumPowerLevelForSendingEventAsStateEvent:kMXEventTypeStringRoomPowerLevels] && oneSelfPowerLevel > memberPowerLevel)
        {
            [actionsArray addObject:@(MXKRoomMemberDetailsActionSetCustomPowerLevel)];
        }
        
        // offer to start a new chat only if the room is not the first direct chat with this user
        // it does not make sense : it would open the same room
        MXRoom* directRoom = [self.mainSession directJoinedRoomWithUserId:_mxRoomMember.userId];
        if (!directRoom || (![directRoom.roomId isEqualToString:mxRoom.roomId]))
        {
            [actionsArray addObject:@(MXKRoomMemberDetailsActionStartChat)];
        }
    }
    
    if (_enableMention)
    {
        // Add mention option
        [actionsArray addObject:@(MXKRoomMemberDetailsActionMention)];
    }
    
    return (actionsArray.count + 1) / 2;
}

- (NSString*)actionButtonTitle:(MXKRoomMemberDetailsAction)action
{
    NSString *title;
    
    switch (action)
    {
        case MXKRoomMemberDetailsActionInvite:
            title = [NSBundle mxk_localizedStringForKey:@"invite"];
            break;
        case MXKRoomMemberDetailsActionLeave:
            title = [NSBundle mxk_localizedStringForKey:@"leave"];
            break;
        case MXKRoomMemberDetailsActionKick:
            title = [NSBundle mxk_localizedStringForKey:@"kick"];
            break;
        case MXKRoomMemberDetailsActionBan:
            title = [NSBundle mxk_localizedStringForKey:@"ban"];
            break;
        case MXKRoomMemberDetailsActionUnban:
            title = [NSBundle mxk_localizedStringForKey:@"unban"];
            break;
        case MXKRoomMemberDetailsActionIgnore:
            title = [NSBundle mxk_localizedStringForKey:@"ignore"];
            break;
        case MXKRoomMemberDetailsActionUnignore:
            title = [NSBundle mxk_localizedStringForKey:@"unignore"];
            break;
        case MXKRoomMemberDetailsActionSetDefaultPowerLevel:
            title = [NSBundle mxk_localizedStringForKey:@"set_default_power_level"];
            break;
        case MXKRoomMemberDetailsActionSetModerator:
            title = [NSBundle mxk_localizedStringForKey:@"set_moderator"];
            break;
        case MXKRoomMemberDetailsActionSetAdmin:
            title = [NSBundle mxk_localizedStringForKey:@"set_admin"];
            break;
        case MXKRoomMemberDetailsActionSetCustomPowerLevel:
            title = [NSBundle mxk_localizedStringForKey:@"set_power_level"];
            break;
        case MXKRoomMemberDetailsActionStartChat:
            title = [NSBundle mxk_localizedStringForKey:@"start_chat"];
            break;
        case MXKRoomMemberDetailsActionStartVoiceCall:
            title = [NSBundle mxk_localizedStringForKey:@"start_voice_call"];
            break;
        case MXKRoomMemberDetailsActionStartVideoCall:
            title = [NSBundle mxk_localizedStringForKey:@"start_video_call"];
            break;
        case MXKRoomMemberDetailsActionMention:
            title = [NSBundle mxk_localizedStringForKey:@"mention"];
            break;
        default:
            break;
    }
    
    return title;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.tableView == tableView)
    {
        NSInteger row = indexPath.row;
        
        MXKTableViewCellWithButtons *cell = [tableView dequeueReusableCellWithIdentifier:[MXKTableViewCellWithButtons defaultReuseIdentifier]];
        if (!cell)
        {
            cell = [[MXKTableViewCellWithButtons alloc] init];
        }
        
        cell.mxkButtonNumber = 2;
        NSArray *buttons = cell.mxkButtons;
        NSInteger index = row * 2;
        NSString *text = nil;
        for (UIButton *button in buttons)
        {
            NSNumber *actionNumber;
            if (index < actionsArray.count)
            {
                actionNumber = [actionsArray objectAtIndex:index];
            }
            
            text = (actionNumber ? [self actionButtonTitle:actionNumber.unsignedIntegerValue] : nil);
            
            button.hidden = (text.length == 0);
            
            button.layer.borderColor = button.tintColor.CGColor;
            button.layer.borderWidth = 1;
            button.layer.cornerRadius = 5;
            
            [button setTitle:text forState:UIControlStateNormal];
            [button setTitle:text forState:UIControlStateHighlighted];
            
            [button addTarget:self action:@selector(onActionButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
            
            button.tag = (actionNumber ? actionNumber.unsignedIntegerValue : -1);
            
            index ++;
        }
        
        return cell;
    }
    
    // Return a fake cell to prevent app from crashing.
    return [[UITableViewCell alloc] init];
}


#pragma mark - button management

- (BOOL)hasPendingAction
{
    return nil != pendingMaskSpinnerView;
}

- (void)addPendingActionMask
{
    // add a spinner above the tableview to avoid that the user tap on any other button
    pendingMaskSpinnerView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    pendingMaskSpinnerView.backgroundColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.5];
    pendingMaskSpinnerView.frame = self.tableView.frame;
    pendingMaskSpinnerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleTopMargin;
    
    // append it
    [self.tableView.superview addSubview:pendingMaskSpinnerView];
    
    // animate it
    [pendingMaskSpinnerView startAnimating];
}

- (void)removePendingActionMask
{
    if (pendingMaskSpinnerView)
    {
        [pendingMaskSpinnerView removeFromSuperview];
        pendingMaskSpinnerView = nil;
        [self.tableView reloadData];
    }
}

- (void)setPowerLevel:(NSInteger)value promptUser:(BOOL)promptUser
{
    NSInteger currentPowerLevel = [self.mxRoomLiveTimeline.state.powerLevels powerLevelOfUserWithUserID:_mxRoomMember.userId];
    
    // check if the power level has not yet been set to 0
    if (value != currentPowerLevel)
    {
        __weak typeof(self) weakSelf = self;

        if (promptUser && value == [self.mxRoomLiveTimeline.state.powerLevels powerLevelOfUserWithUserID:self.mainSession.myUser.userId])
        {
            // If the user is setting the same power level as his to another user, ask him for a confirmation
            if (currentAlert)
            {
                [currentAlert dismissViewControllerAnimated:NO completion:nil];
            }
            
            currentAlert = [UIAlertController alertControllerWithTitle:[NSBundle mxk_localizedStringForKey:@"room_member_power_level_prompt"] message:nil preferredStyle:UIAlertControllerStyleAlert];
            
            [currentAlert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"no"]
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction * action) {
                                                               
                                                               if (weakSelf)
                                                               {
                                                                   typeof(self) self = weakSelf;
                                                                   self->currentAlert = nil;
                                                               }
                                                               
                                                           }]];
            
            [currentAlert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"yes"]
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction * action) {
                                                               
                                                               if (weakSelf)
                                                               {
                                                                   typeof(self) self = weakSelf;
                                                                   self->currentAlert = nil;
                                                                   
                                                                   // The user confirms. Apply the power level
                                                                   [self setPowerLevel:value promptUser:NO];
                                                               }
                                                               
                                                           }]];
            
            [self presentViewController:currentAlert animated:YES completion:nil];
        }
        else
        {
            [self addPendingActionMask];

            // Reset user power level
            [self.mxRoom setPowerLevelOfUserWithUserID:_mxRoomMember.userId powerLevel:value success:^{

                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf removePendingActionMask];

            } failure:^(NSError *error) {

                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf removePendingActionMask];
                NSLog(@"[MXKRoomMemberDetailsVC] Set user power (%@) failed", strongSelf.mxRoomMember.userId);

                // Notify MatrixKit user
                NSString *myUserId = strongSelf.mainSession.myUser.userId;
                [[NSNotificationCenter defaultCenter] postNotificationName:kMXKErrorNotification object:error userInfo:myUserId ? @{kMXKErrorUserIdKey: myUserId} : nil];
                
            }];
        }
    }
}

- (void)updateUserPowerLevel
{
    __weak typeof(self) weakSelf = self;
    
    if (currentAlert)
    {
        [currentAlert dismissViewControllerAnimated:NO completion:nil];
    }
    
    currentAlert = [UIAlertController alertControllerWithTitle:[NSBundle mxk_localizedStringForKey:@"power_level"] message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    
    if (![self.mainSession.myUser.userId isEqualToString:_mxRoomMember.userId])
    {
        [currentAlert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"reset_to_default"]
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * action) {
                                                           
                                                           if (weakSelf)
                                                           {
                                                               typeof(self) self = weakSelf;
                                                               self->currentAlert = nil;
                                                               
                                                               [self setPowerLevel:self.mxRoomLiveTimeline.state.powerLevels.usersDefault promptUser:YES];
                                                           }
                                                           
                                                       }]];
    }
    
    [currentAlert addTextFieldWithConfigurationHandler:^(UITextField *textField)
    {
        typeof(self) self = weakSelf;
        
        textField.secureTextEntry = NO;
        textField.text = [NSString stringWithFormat:@"%ld", (long)[self.mxRoomLiveTimeline.state.powerLevels powerLevelOfUserWithUserID:self.mxRoomMember.userId]];
        textField.placeholder = nil;
        textField.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    
    [currentAlert addAction:[UIAlertAction actionWithTitle:[NSBundle mxk_localizedStringForKey:@"ok"]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction * action) {
                                                       
                                                       if (weakSelf)
                                                       {
                                                           typeof(self) self = weakSelf;
                                                           UITextField *textField = [self->currentAlert textFields].firstObject;
                                                           self->currentAlert = nil;
                                                           
                                                           if (textField.text.length > 0)
                                                           {
                                                               [self setPowerLevel:[textField.text integerValue] promptUser:YES];
                                                           }
                                                       }
                                                       
                                                   }]];
    
    [self presentViewController:currentAlert animated:YES completion:nil];
}

@end
