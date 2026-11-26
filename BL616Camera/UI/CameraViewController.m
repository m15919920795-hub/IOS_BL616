#import "CameraViewController.h"
#import "HBUDPClient.h"

@interface CameraViewController () <HBUDPClientDelegate>
@end
@implementation CameraViewController {
    HBUDPClient *_client;
    UIImageView *_preview;
    UITextField *_host, *_remotePort, *_localPort;
    UIButton *_connect, *_disconnect, *_start, *_stop, *_neutralTXTest;
    UIButton *_controlsToggle;
    UIVisualEffectView *_controlsPanel;
    UILabel *_status;
    HBClientState _clientState;
    uint64_t _generation;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _preview = [[UIImageView alloc] init];
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    _preview.backgroundColor = UIColor.blackColor;
    _preview.contentMode = UIViewContentModeScaleAspectFit;
    _preview.accessibilityLabel = @"摄像头实时画面";
    _preview.userInteractionEnabled = YES;
    [self.view addSubview:_preview];
    [NSLayoutConstraint activateConstraints:@[
        [_preview.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_preview.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_preview.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_preview.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    [_preview addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controlsTapped)]];

    _controlsPanel = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _controlsPanel.translatesAutoresizingMaskIntoConstraints = NO;
    _controlsPanel.layer.cornerRadius = 18;
    _controlsPanel.clipsToBounds = YES;
    _controlsPanel.hidden = YES;
    _controlsPanel.accessibilityIdentifier = @"cameraControlsPanel";
    [self.view addSubview:_controlsPanel];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *panelWidth = [_controlsPanel.widthAnchor constraintEqualToConstant:480];
    panelWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *panelBottom = [_controlsPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8];
    panelBottom.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        panelWidth, panelBottom,
        [_controlsPanel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32],
        [_controlsPanel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_controlsPanel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [_controlsPanel.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8]
    ]];
    UILabel *title = [self label:@"连接与图传" size:20];
    title.font = [UIFont boldSystemFontOfSize:20];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.configuration = [UIButtonConfiguration plainButtonConfiguration];
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor = UIColor.whiteColor;
    close.accessibilityLabel = @"收起控制面板";
    [close addTarget:self action:@selector(controlsTapped) forControlEvents:UIControlEventTouchUpInside];
    [close.widthAnchor constraintEqualToConstant:44].active = YES;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, close]];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.alignment = UIStackViewAlignmentCenter;
    [_controlsPanel.contentView addSubview:header];
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [_controlsPanel.contentView addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:_controlsPanel.contentView.topAnchor constant:8],
        [header.leadingAnchor constraintEqualToAnchor:_controlsPanel.contentView.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:_controlsPanel.contentView.trailingAnchor constant:-8],
        [header.heightAnchor constraintEqualToConstant:44],
        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],
        [scroll.bottomAnchor constraintEqualToAnchor:_controlsPanel.contentView.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:_controlsPanel.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_controlsPanel.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]
    ]];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // Apply the test board's ports once, including installs with the old defaults saved.
    if ([defaults integerForKey:@"portDefaultsVersion"] < 1) {
        if ([[defaults stringForKey:@"remotePort"] isEqualToString:@"8800"])
            [defaults setObject:@"8801" forKey:@"remotePort"];
        if ([[defaults stringForKey:@"localPort"] isEqualToString:@"9000"])
            [defaults setObject:@"1235" forKey:@"localPort"];
        [defaults setInteger:1 forKey:@"portDefaultsVersion"];
    }
    _host = [self field:([defaults stringForKey:@"deviceIP"] ?: @"192.168.169.1") numeric:NO];
    _remotePort = [self field:([defaults stringForKey:@"remotePort"] ?: @"8801") numeric:YES];
    _localPort = [self field:([defaults stringForKey:@"localPort"] ?: @"1235") numeric:YES];
    [stack addArrangedSubview:[self row:@"设备 IP" field:_host]];
    [stack addArrangedSubview:[self row:@"设备端口" field:_remotePort]];
    [stack addArrangedSubview:[self row:@"本地端口" field:_localPort]];
    _connect = [self button:@"连接 UDP" action:@selector(connectTapped)];
    _disconnect = [self button:@"断开 UDP" action:@selector(disconnectTapped)];
    _start = [self button:@"开启图传" action:@selector(startTapped)];
    _stop = [self button:@"关闭图传" action:@selector(stopTapped)];
    for (NSArray<UIButton *> *buttons in @[@[_connect, _disconnect], @[_start, _stop]]) {
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
        row.distribution = UIStackViewDistributionFillEqually; row.spacing = 12;
        [stack addArrangedSubview:row];
    }
    _neutralTXTest = [self button:@"发送串口测试（B 固件）" action:@selector(neutralTXTapped)];
    _neutralTXTest.accessibilityIdentifier = @"neutralTXTest";
    [stack addArrangedSubview:_neutralTXTest];
    _status = [self label:@"未连接" size:15];
    _status.accessibilityIdentifier = @"connectionStatus";
    [stack addArrangedSubview:_status];
    _controlsToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *toggleStyle = [UIButtonConfiguration filledButtonConfiguration];
    toggleStyle.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
    toggleStyle.baseForegroundColor = UIColor.whiteColor;
    toggleStyle.baseBackgroundColor = [UIColor colorWithWhite:0.12 alpha:0.7];
    toggleStyle.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    _controlsToggle.configuration = toggleStyle;
    _controlsToggle.translatesAutoresizingMaskIntoConstraints = NO;
    _controlsToggle.accessibilityLabel = @"显示连接与图传控制";
    [_controlsToggle addTarget:self action:@selector(controlsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_controlsToggle];
    [NSLayoutConstraint activateConstraints:@[
        [_controlsToggle.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [_controlsToggle.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_controlsToggle.widthAnchor constraintEqualToConstant:44],
        [_controlsToggle.heightAnchor constraintEqualToConstant:44]
    ]];
    _client = [[HBUDPClient alloc] init]; _client.delegate = self;
    [self updateControls:HBClientDisconnected];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:)
        name:UISceneDidEnterBackgroundNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; _client.delegate = nil; [_client disconnect]; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (BOOL)shouldAutorotate { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return _controlsPanel.hidden; }
- (void)controlsTapped { [self setControlsVisible:_controlsPanel.hidden]; }
- (void)setControlsVisible:(BOOL)visible {
    if (!visible) [self hideKeyboard];
    _controlsPanel.hidden = !visible;
    _controlsToggle.hidden = visible;
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (UILabel *)label:(NSString *)text size:(CGFloat)size {
    UILabel *label = [[UILabel alloc] init]; label.text = text; label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:size]; return label;
}
- (UITextField *)field:(NSString *)value numeric:(BOOL)numeric {
    UITextField *field = [[UITextField alloc] init]; field.text = value;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = numeric ? UIKeyboardTypeNumberPad : UIKeyboardTypeNumbersAndPunctuation;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    return field;
}
- (UIStackView *)row:(NSString *)title field:(UITextField *)field {
    UILabel *label = [self label:title size:15];
    [label.widthAnchor constraintEqualToConstant:80].active = YES;
    field.accessibilityLabel = title;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, field]];
    row.spacing = 12; return row;
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(14, 8, 14, 8);
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (BOOL)readPort:(UITextField *)field allowZero:(BOOL)zero value:(uint16_t *)value {
    NSString *text = field.text ?: @"";
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    if (!text.length || text.length > 5 || [text rangeOfCharacterFromSet:invalid].location != NSNotFound ||
        text.integerValue > 65535 || (!zero && text.integerValue == 0)) return NO;
    *value = (uint16_t)text.integerValue; return YES;
}
- (void)connectTapped {
    [self hideKeyboard]; uint16_t remote, local;
    if (![self readPort:_remotePort allowZero:NO value:&remote] || ![self readPort:_localPort allowZero:YES value:&local]) {
        _status.text = @"设备端口应为 1–65535，本地端口可为 0（自动分配）"; return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:_host.text forKey:@"deviceIP"];
    [defaults setObject:_remotePort.text forKey:@"remotePort"];
    [defaults setObject:_localPort.text forKey:@"localPort"];
    [_client connectToHost:_host.text ?: @"" remotePort:remote localPort:local];
}
- (void)disconnectTapped { [_client disconnect]; }
- (void)startTapped { [_client startVideo]; }
- (void)stopTapped { [_client stopVideo]; }
- (void)neutralTXTapped {
    [self updateNeutralTXTest:!_neutralTXTest.selected];
}
- (void)updateNeutralTXTest:(BOOL)enabled {
    const uint8_t neutral[] = {0x33, 0x80, 0x80, 0x00, 0x88};
    NSData *data = enabled ? [NSData dataWithBytes:neutral length:sizeof(neutral)] : nil;
    if (![_client setTXControlData:data]) return;
    _neutralTXTest.selected = enabled;
    UIButtonConfiguration *configuration = _neutralTXTest.configuration;
    configuration.title = enabled ? @"停止串口测试" : @"发送串口测试（B 固件）";
    _neutralTXTest.configuration = configuration;
}
- (void)hideKeyboard { [self.view endEditing:YES]; }
- (void)backgrounded:(NSNotification *)notification { (void)notification; [_client disconnect]; }
- (void)updateControls:(HBClientState)state {
    BOOL editable = state == HBClientDisconnected;
    _host.enabled = editable; _remotePort.enabled = editable; _localPort.enabled = editable;
    _connect.enabled = editable;
    _disconnect.enabled = !editable && state != HBClientDisconnecting;
    _start.enabled = state == HBClientReady;
    _stop.enabled = state == HBClientReady || state == HBClientStarting || state == HBClientStreaming;
    _neutralTXTest.enabled = state == HBClientStreaming;
    if (!_neutralTXTest.enabled && _neutralTXTest.selected) [self updateNeutralTXTest:NO];
}
- (void)client:(HBUDPClient *)client didUpdateState:(HBClientState)state
    generation:(uint64_t)generation localPort:(uint16_t)localPort message:(NSString *)message {
    (void)client; (void)localPort;
    if (generation != _generation) {
        _generation = generation;
        _preview.image = nil;
    }
    HBClientState previousState = _clientState;
    _clientState = state;
    [self updateControls:state];
    _status.text = message;
    if (_clientState == HBClientStreaming && previousState != HBClientStreaming)
        [self setControlsVisible:NO];
    else if ((_clientState == HBClientDisconnected && previousState != HBClientDisconnected) ||
             (_clientState == HBClientStopping &&
              (previousState == HBClientStarting || previousState == HBClientStreaming)))
        [self setControlsVisible:YES];
}
- (void)client:(HBUDPClient *)client didReceiveImage:(UIImage *)image generation:(uint64_t)generation {
    (void)client;
    if (generation == _generation) _preview.image = image;
}
@end
