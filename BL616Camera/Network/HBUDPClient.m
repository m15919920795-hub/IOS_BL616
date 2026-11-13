#import "HBUDPClient.h"
#import "HBProtocol.h"
#import <CocoaAsyncSocket/GCDAsyncUdpSocket.h>
#import <arpa/inet.h>

static uint64_t HBNow(void) { return (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000.0); }

@interface HBUDPClient () <GCDAsyncUdpSocketDelegate> {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    GCDAsyncUdpSocket *_socket;
    HBReceiver _receiver;
    HBClientState _state;
    uint64_t _generation, _startAt, _startDeadline, _lastStart, _stopUntil;
    uint64_t _lastFrame, _lastPublished, _lastDelivered;
    uint64_t _packets, _frames, _invalid, _dropped;
    BOOL _seenFirstFragment;
    uint16_t _localPort;
    NSString *_detail;
    NSData *_pendingJPEG;
    uint64_t _pendingJPEGGeneration;
    BOOL _frameDeliveryScheduled;
}
@end

@implementation HBUDPClient
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.guanxukeji.bl616.udp", DISPATCH_QUEUE_SERIAL);
        _detail = @"未连接";
    }
    return self;
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    [_socket setDelegate:nil];
    [_socket close];
    hb_receiver_reset(&_receiver);
}

- (void)publish:(NSString *)message {
    if (message) _detail = [message copy];
    NSDictionary *status = @{@"state": @(_state), @"generation": @(_generation),
        @"detail": _detail ?: @"", @"localPort": @(_localPort), @"packets": @(_packets),
        @"frames": @(_frames), @"invalid": @(_invalid), @"dropped": @(_dropped)};
    _lastPublished = HBNow();
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate client:self didUpdateStatus:status]; });
}

- (void)closeSocket {
    [_socket setDelegate:nil];
    [_socket close];
    _socket = nil;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    hb_receiver_reset(&_receiver);
    _pendingJPEG = nil;
    _localPort = 0;
}

- (void)fail:(NSString *)message {
    _generation++;
    [self closeSocket];
    _state = HBClientDisconnected;
    [self publish:message];
}

- (void)sendCommand:(BOOL)start {
    if (!_socket.isConnected) return;
    uint8_t bytes[4]; hb_write_command(bytes, start);
    [_socket sendData:[NSData dataWithBytes:bytes length:sizeof(bytes)] withTimeout:1 tag:start ? 1 : 2];
}

- (void)connectToHost:(NSString *)host remotePort:(uint16_t)remotePort localPort:(uint16_t)localPort {
    NSString *address = [host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    dispatch_async(_queue, ^{
        if (self->_state != HBClientDisconnected) return;
        struct in_addr ip;
        if (!remotePort || inet_pton(AF_INET, address.UTF8String, &ip) != 1 ||
            ip.s_addr == INADDR_ANY || (ntohl(ip.s_addr) >> 24) >= 224) {
            [self publish:@"请输入有效的设备 IPv4 地址和目标端口"];
            return;
        }
        self->_generation++;
        self->_packets = self->_frames = self->_invalid = self->_dropped = 0;
        self->_state = HBClientConnecting;
        [self publish:@"正在绑定本地 UDP 端口…"];
        self->_socket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:self->_queue];
        [self->_socket setIPv6Enabled:NO];
        NSError *error = nil;
        if (![self->_socket bindToPort:localPort error:&error] ||
            ![self->_socket connectToHost:address onPort:remotePort error:&error]) {
            [self fail:[NSString stringWithFormat:@"UDP 初始化失败：%@", error.localizedDescription ?: @"未知错误"]];
        }
    });
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didConnectToAddress:(NSData *)address {
    (void)address;
    if (sock != _socket || _state != HBClientConnecting) return;
    NSError *error = nil;
    if (![sock beginReceiving:&error]) { [self fail:error.localizedDescription]; return; }
    _localPort = sock.localPort;
    _state = HBClientReady;
    [self publish:@"UDP 会话就绪；尚未验证设备在线"];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC),
                             20 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    __weak HBUDPClient *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}

- (void)startVideo {
    dispatch_async(_queue, ^{
        if (self->_state != HBClientReady) return;
        self->_generation++;
        hb_receiver_reset(&self->_receiver);
        self->_pendingJPEG = nil;
        self->_lastDelivered = 0;
        self->_seenFirstFragment = NO;
        self->_lastStart = 0;
        self->_startAt = HBNow() + 150;
        self->_startDeadline = self->_startAt + 5000;
        self->_state = HBClientStarting;
        /* Clear an abandoned sender session before START; retain this source port. */
        [self sendCommand:NO];
        [self sendCommand:NO];
        [self publish:@"正在开启图传，等待第一帧…"];
    });
}

- (void)stopOnQueue:(NSString *)message {
    _generation++;
    _state = HBClientStopping;
    [self sendCommand:NO]; [self sendCommand:NO]; [self sendCommand:NO];
    hb_receiver_reset(&_receiver);
    _pendingJPEG = nil;
    _stopUntil = HBNow() + 200;
    [self publish:message];
}

- (void)stopVideo {
    dispatch_async(_queue, ^{
        if (self->_state == HBClientReady || self->_state == HBClientStarting || self->_state == HBClientStreaming)
            [self stopOnQueue:@"关闭图传请求已发送；协议没有 STOP 应答"];
    });
}

- (void)disconnect {
    dispatch_async(_queue, ^{
        if (self->_state == HBClientDisconnected || self->_state == HBClientDisconnecting) return;
        self->_generation++;
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        hb_receiver_reset(&self->_receiver);
        self->_pendingJPEG = nil;
        self->_state = HBClientDisconnecting;
        [self publish:@"正在关闭 UDP；已清理本地画面和队列"];
        if (self->_socket.isConnected) {
            [self sendCommand:NO]; [self sendCommand:NO]; [self sendCommand:NO];
            [self->_socket closeAfterSending];
        } else {
            [self closeSocket];
            self->_state = HBClientDisconnected;
            [self publish:@"UDP 已断开"];
        }
    });
}

- (void)ackFrame:(HBFrame *)frame {
    uint8_t bytes[48 + HB_BITMAP_SIZE];
    size_t length = hb_write_ack(bytes, sizeof(bytes), frame->info.sequence, frame->status,
                                 frame->bitmap, frame->info.count);
    if (length) [_socket sendData:[NSData dataWithBytes:bytes length:length] withTimeout:0.3 tag:3];
}

- (void)deliverJPEG:(NSData *)jpeg {
    _pendingJPEG = jpeg;
    _pendingJPEGGeneration = _generation;
    if (_frameDeliveryScheduled) return;
    _frameDeliveryScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        __block NSData *latest = nil;
        __block uint64_t generation = 0;
        dispatch_sync(self->_queue, ^{
            latest = self->_pendingJPEG;
            generation = self->_pendingJPEGGeneration;
            self->_pendingJPEG = nil;
            self->_frameDeliveryScheduled = NO;
        });
        if (latest) [self.delegate client:self didReceiveJPEG:latest generation:generation];
    });
}

- (void)tick {
    uint64_t now = HBNow();
    if (_state == HBClientStarting) {
        if (now >= _startDeadline) {
            [self stopOnQueue:@"开启超时：未收到完整图像，请检查设备 IP、摄像头和本地网络权限"];
            return;
        }
        if (!_seenFirstFragment && now >= _startAt && (!_lastStart || now - _lastStart >= 100)) {
            [self sendCommand:YES]; _lastStart = now;
        }
    }
    if (_state == HBClientStreaming && now - _lastFrame > 3000) {
        [self stopOnQueue:@"图像已超时，已请求停止；可重新开启图传"];
        return;
    }
    if ((_state == HBClientStarting && _seenFirstFragment) || _state == HBClientStreaming) {
        unsigned partialBefore = 0, partialAfter = 0;
        for (unsigned i = 0; i < HB_FRAME_SLOTS; i++)
            if (_receiver.frames[i].used && _receiver.frames[i].status == HB_ACK_PARTIAL) partialBefore++;
        hb_receiver_expire(&_receiver, now);
        for (unsigned i = 0; i < HB_FRAME_SLOTS; i++)
            if (_receiver.frames[i].used && _receiver.frames[i].status == HB_ACK_PARTIAL) partialAfter++;
        _dropped += partialBefore - partialAfter;
        for (unsigned i = 0; i < HB_FRAME_SLOTS; i++)
            if (_receiver.frames[i].used) [self ackFrame:&_receiver.frames[i]];
    }
    if (_state == HBClientStopping && now >= _stopUntil) {
        _state = HBClientReady;
        [self publish:nil];
    } else if (now - _lastPublished >= 1000) [self publish:nil];
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address withFilterContext:(id)filterContext {
    (void)address; (void)filterContext;
    if (sock != _socket || (_state != HBClientStarting && _state != HBClientStreaming)) return;
    /* Connected UDP filters the remote IP/port in GCDAsyncUdpSocket. */
    HBFragment fragment;
    if (!hb_parse_fragment(data.bytes, data.length, &fragment)) { _invalid++; return; }
    if (_state == HBClientStarting && (!_lastStart || (!_seenFirstFragment && fragment.sequence != 1))) return;
    _seenFirstFragment = YES;
    _packets++;
    HBFrame *frame = NULL;
    HBResult result = hb_receiver_feed(&_receiver, data.bytes, data.length, HBNow(), &frame);
    if (result == HB_OLD || result == HB_NO_MEMORY) {
        HBFrame dropped = {0}; dropped.info = fragment; dropped.status = HB_ACK_DROP;
        [self ackFrame:&dropped]; _dropped++;
        return;
    }
    if (result == HB_INVALID) { _invalid++; return; }
    if (result == HB_COMPLETE || (result == HB_DUPLICATE && frame->status != HB_ACK_PARTIAL)) [self ackFrame:frame];
    if (result != HB_COMPLETE) return;
    if (fragment.sequence <= _lastDelivered) { hb_frame_release_payload(frame); return; }
    _lastDelivered = fragment.sequence;
    _lastFrame = HBNow();
    _frames++;
    NSData *jpeg = [NSData dataWithBytes:frame->bytes length:frame->info.frame_size];
    hb_frame_release_payload(frame);
    if (_state != HBClientStreaming) {
        _state = HBClientStreaming;
        [self publish:@"已收到完整 JPEG，图传进行中"];
    }
    [self deliverJPEG:jpeg];
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotConnect:(NSError *)error {
    if (sock == _socket) [self fail:[NSString stringWithFormat:@"UDP 初始化失败：%@", error.localizedDescription ?: @"未知错误"]];
}
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error {
    if (sock != _socket) return;
    if (_state == HBClientDisconnecting) { [self closeSocket]; _state = HBClientDisconnected; [self publish:@"UDP 已关闭；STOP 未确认送达"];
    } else [self fail:[NSString stringWithFormat:@"UDP 发送失败（%ld）：%@", tag, error.localizedDescription ?: @"未知错误"]];
}
- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)sock withError:(NSError *)error {
    if (sock != _socket) return;
    BOOL requested = _state == HBClientDisconnecting;
    [self fail:requested ? @"UDP 已断开；设备停止情况需以板端为准" :
        [NSString stringWithFormat:@"UDP 已关闭：%@", error.localizedDescription ?: @"连接终止"]];
}
@end
