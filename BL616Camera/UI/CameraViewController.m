#import "CameraViewController.h"
#import "HBUDPClient.h"
#import "JPEGRenderer.h"

@interface CameraViewController () <HBUDPClientDelegate>
@end
@implementation CameraViewController {
    HBUDPClient *_client;
    JPEGRenderer *_renderer;
    UITextField *_host, *_remotePort, *_localPort;
    UIButton *_connect, *_disconnect, *_start, *_stop;
    UILabel *_status, *_statistics;
    uint64_t _generation;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    UILabel *title = [self label:@"BL616 摄像板" size:28];
    title.font = [UIFont boldSystemFontOfSize:28];
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:[self label:@"Wi-Fi 图传 · HiBooster UDP / JPEG" size:14]];
    UIImageView *preview = [[UIImageView alloc] init];
    preview.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    preview.contentMode = UIViewContentModeScaleAspectFit;
    preview.layer.cornerRadius = 12; preview.clipsToBounds = YES;
    preview.accessibilityLabel = @"摄像头实时画面";
    [preview.heightAnchor constraintEqualToAnchor:preview.widthAnchor multiplier:0.75].active = YES;
    [stack addArrangedSubview:preview];
    _renderer = [[JPEGRenderer alloc] initWithImageView:preview];
    __weak CameraViewController *weakSelf = self;
    _renderer.decodeError = ^{
        CameraViewController *strongSelf = weakSelf;
        if (strongSelf) strongSelf->_status.text = @"收到的 JPEG 无法解码，请检查板端图像格式";
    };
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
    _status = [self label:@"未连接" size:15];
    _status.accessibilityIdentifier = @"connectionStatus";
    _statistics = [self label:@"本地监听：—\nUDP 收包：0 · 字节：0\n有效分片：0 · 完整帧：0" size:13];
    [stack addArrangedSubview:_status]; [stack addArrangedSubview:_statistics];
    UILabel *help = [self label:@"先在系统 Wi-Fi 设置中连接摄像板所在网络，并允许本地网络访问。默认 IP 仅适用于板端已开启默认 AP 的情况。UDP 就绪表示本地会话已建立，收到图像后才确认图传。" size:13];
    help.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:help];
    _client = [[HBUDPClient alloc] init]; _client.delegate = self;
    [self updateControls:HBClientDisconnected];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounded:)
        name:UISceneDidEnterBackgroundNotification object:nil];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideKeyboard)];
    tap.cancelsTouchesInView = NO; [self.view addGestureRecognizer:tap];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; _client.delegate = nil; [_client disconnect]; }
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
- (void)hideKeyboard { [self.view endEditing:YES]; }
- (void)backgrounded:(NSNotification *)notification { (void)notification; [_client disconnect]; }
- (void)updateControls:(HBClientState)state {
    BOOL editable = state == HBClientDisconnected;
    _host.enabled = editable; _remotePort.enabled = editable; _localPort.enabled = editable;
    _connect.enabled = editable;
    _disconnect.enabled = !editable && state != HBClientDisconnecting;
    _start.enabled = state == HBClientReady;
    _stop.enabled = state == HBClientReady || state == HBClientStarting || state == HBClientStreaming;
}
- (void)client:(HBUDPClient *)client didUpdateStatus:(NSDictionary<NSString *,id> *)status {
    (void)client;
    uint64_t generation = [status[@"generation"] unsignedLongLongValue];
    if (generation != _generation) { _generation = generation; [_renderer resetForGeneration:generation]; }
    [self updateControls:[status[@"state"] integerValue]];
    _status.text = status[@"detail"];
    _statistics.text = [NSString stringWithFormat:@"本地监听：%@\nUDP 收包：%@ · 字节：%@\n有效分片：%@ · 完整帧：%@\n无效分片：%@ · 过期/拒收：%@\n最近来源：%@\n首包（最多 64 字节）：%@",
        status[@"localPort"], status[@"datagrams"], status[@"receivedBytes"], status[@"packets"],
        status[@"frames"], status[@"invalid"], status[@"dropped"], status[@"lastSource"], status[@"firstPacket"]];
}
- (void)client:(HBUDPClient *)client didReceiveJPEG:(NSData *)jpeg generation:(uint64_t)generation {
    (void)client; [_renderer submitJPEG:jpeg generation:generation];
}
@end
