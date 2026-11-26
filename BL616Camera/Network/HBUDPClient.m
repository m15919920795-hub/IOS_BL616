#import "HBUDPClient.h"
#import "HBProtocol.h"
#import "JPEGRenderer.h"
@import CocoaAsyncSocket;
#import <arpa/inet.h>

static uint64_t HBNow(void) { return (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000.0); }

@interface HBUDPClient () <GCDAsyncUdpSocketDelegate> {
    dispatch_queue_t _queue;
    dispatch_queue_t _decodeQueue;
    dispatch_source_t _timer;
    GCDAsyncUdpSocket *_socket;
    NSData *_commandAddress;
    NSString *_deviceHost;
    HBReceiver _receiver;
    BOOL _usesBAcks;
    NSData *_txControlData;
    uint32_t _bControlSequence;
    HBClientState _state;
    uint64_t _startAt, _startDeadline, _lastStart, _stopUntil;
    uint64_t _lastFrame, _lastQueuedFrame;
    BOOL _seenDatagram, _seenFirstFragment, _decodeFailed;
    uint16_t _localPort;
    NSString *_detail;
    NSData *_pendingJPEG;
    BOOL _decoding;
}
@property(atomic) uint64_t generation;
@end

@implementation HBUDPClient
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.guanxukeji.bl616.udp", DISPATCH_QUEUE_SERIAL);
        _decodeQueue = dispatch_queue_create("com.guanxukeji.bl616.jpeg", DISPATCH_QUEUE_SERIAL);
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
    HBClientState state = _state;
    uint64_t generation = self.generation;
    uint16_t localPort = _localPort;
    NSString *detail = _detail;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate client:self didUpdateState:state generation:generation localPort:localPort message:detail];
    });
}

- (void)closeSocket {
    _usesBAcks = NO;
    _txControlData = nil;
    _bControlSequence = 0;
    [_socket setDelegate:nil];
    [_socket close];
    _socket = nil;
    _commandAddress = nil;
    _deviceHost = nil;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    hb_receiver_reset(&_receiver);
    _pendingJPEG = nil;
    _localPort = 0;
}

- (void)fail:(NSString *)message {
    self.generation++;
    [self closeSocket];
    _state = HBClientDisconnected;
    [self publish:message];
}

- (void)sendCommand:(BOOL)start {
    if (!_socket || _socket.isClosed || !_commandAddress) return;
    uint8_t bytes[4]; hb_write_command(bytes, start);
    [_socket sendData:[NSData dataWithBytes:bytes length:sizeof(bytes)] toAddress:_commandAddress
         withTimeout:1 tag:start ? 1 : 2];
}

#pragma mark - UDP connection

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
        self.generation++;
        self->_deviceHost = [address copy];
        struct sockaddr_in endpoint = {0};
        endpoint.sin_len = sizeof(endpoint);
        endpoint.sin_family = AF_INET;
        endpoint.sin_port = htons(remotePort);
        endpoint.sin_addr = ip;
        self->_commandAddress = [NSData dataWithBytes:&endpoint length:sizeof(endpoint)];
        self->_state = HBClientConnecting;
        [self publish:@"正在绑定本地 UDP 端口…"];
        self->_socket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:self->_queue];
        [self->_socket setIPv6Enabled:NO];
        [self->_socket setMaxReceiveIPv4BufferSize:UINT16_MAX];
        NSError *error = nil;
        if (![self->_socket bindToPort:localPort error:&error]) {
            [self fail:[NSString stringWithFormat:@"无法监听本地端口 %u：%@。请先关闭 UDP 助手等占用此端口的应用",
                        (unsigned)localPort, error.localizedDescription ?: @"未知错误"]];
            return;
        }
        [self beginSession];
    });
}

- (void)beginSession {
    NSError *error = nil;
    if (![_socket beginReceiving:&error]) { [self fail:error.localizedDescription]; return; }
    _localPort = _socket.localPort;
    _state = HBClientReady;
    [self publish:@"UDP 已就绪，可以开启图传"];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = HB_ACK_INTERVAL_MS * NSEC_PER_MSEC;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, interval),
                             interval, 2 * NSEC_PER_MSEC);
    __weak HBUDPClient *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}

- (void)disconnect {
    dispatch_async(_queue, ^{
        if (self->_state == HBClientDisconnected || self->_state == HBClientDisconnecting) return;
        self.generation++;
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        hb_receiver_reset(&self->_receiver);
        self->_pendingJPEG = nil;
        self->_state = HBClientDisconnecting;
        [self publish:@"正在断开 UDP…"];
        if (self->_socket && !self->_socket.isClosed) {
            [self sendCommand:NO]; [self sendCommand:NO]; [self sendCommand:NO];
            [self->_socket closeAfterSending];
        } else {
            [self closeSocket];
            self->_state = HBClientDisconnected;
            [self publish:@"UDP 已断开"];
        }
    });
}

#pragma mark - Video control

- (void)startVideo {
    dispatch_async(_queue, ^{
        if (self->_state != HBClientReady) return;
        self.generation++;
        hb_receiver_reset(&self->_receiver);
        self->_pendingJPEG = nil;
        self->_lastQueuedFrame = 0;
        self->_lastFrame = 0;
        self->_seenDatagram = NO;
        self->_seenFirstFragment = NO;
        self->_decodeFailed = NO;
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
    _usesBAcks = NO;
    _txControlData = nil;
    _bControlSequence = 0;
    self.generation++;
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
            [self stopOnQueue:@"已发送关闭图传指令"];
    });
}

#pragma mark - TX control data

- (BOOL)setTXControlData:(NSData *)data {
    if (data && (!data.length || data.length > HB_B_CONTROL_MAX_SIZE)) return NO;
    NSData *payload = [data copy];
    __block BOOL accepted = YES;
    dispatch_sync(_queue, ^{
        if (payload && self->_state != HBClientStreaming) {
            accepted = NO;
            return;
        }
        if (payload) self->_usesBAcks = YES;
        if (!payload && self->_txControlData) {
            // A single control sequence update marks the end of control.
            self->_bControlSequence++;
        }
        self->_txControlData = payload;
    });
    return accepted;
}

- (void)ackFrame:(HBFrame *)frame at:(uint64_t)now {
    uint8_t bytes[HB_ACK_MAX_SIZE];
    HBAckControl control = {
        .bytes = _txControlData.bytes,
        .length = _txControlData.length,
        .sequence = _bControlSequence + (_txControlData ? 1u : 0u),
    };
    size_t length = hb_prepare_frame_ack(frame, now, bytes, sizeof(bytes), _usesBAcks ? &control : NULL);
    if (length) {
        _bControlSequence = control.sequence;
        [_socket sendData:[NSData dataWithBytes:bytes length:length] toAddress:_commandAddress
              withTimeout:0.3 tag:3];
    }
}

#pragma mark - JPEG decoding and UIImage delivery

- (void)finishDecoding {
    _decoding = NO;
    [self decodeNextJPEG];
}

/* Called on the UDP queue. Keep one in-flight image and the latest pending JPEG. */
- (void)decodeNextJPEG {
    if (_decoding || !_pendingJPEG) return;
    NSData *jpeg = _pendingJPEG;
    _pendingJPEG = nil;
    _decoding = YES;
    uint64_t generation = self.generation;
    dispatch_async(_decodeQueue, ^{
        @autoreleasepool {
            UIImage *image = HBDecodeJPEG(jpeg);
            dispatch_async(self->_queue, ^{
                if (generation != self.generation) {
                    [self finishDecoding];
                    return;
                }
                if (!image) {
                    self->_decodeFailed = YES;
                    [self finishDecoding];
                    return;
                }
                self->_decodeFailed = NO;
                if (self->_state == HBClientStarting) {
                    self->_state = HBClientStreaming;
                    [self publish:@"图传进行中"];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == self.generation) {
                        [self.delegate client:self didReceiveImage:image generation:generation];
                    }
                    dispatch_async(self->_queue, ^{ [self finishDecoding]; });
                });
            });
        }
    });
}

#pragma mark - UDP receive and timeouts

- (void)tick {
    uint64_t now = HBNow();
    if (_state == HBClientStarting) {
        if (now >= _startDeadline) {
            NSString *message = @"开启超时：未收到设备 UDP 数据，请检查设备 IP、本地网络权限和端口占用";
            if (_decodeFailed)
                message = @"开启超时：收到的 JPEG 无法解码";
            else if (_seenFirstFragment)
                message = @"开启超时：已收到有效分片，但未收齐完整图像";
            else if (_seenDatagram)
                message = @"开启超时：已收到 UDP 数据，但未识别出有效图像分片";
            [self stopOnQueue:message];
            return;
        }
        if (!_seenFirstFragment && now >= _startAt && (!_lastStart || now - _lastStart >= 100)) {
            [self sendCommand:YES]; _lastStart = now;
        }
    }
    if (_state == HBClientStreaming && now - _lastFrame > 3000) {
        [self stopOnQueue:@"图像接收超时，可重新开启图传"];
        return;
    }
    if ((_state == HBClientStarting && _seenFirstFragment) || _state == HBClientStreaming) {
        hb_receiver_expire(&_receiver, now);
        for (unsigned i = 0; i < HB_FRAME_SLOTS; i++) {
            HBFrame *frame = &_receiver.frames[i];
            if (hb_receiver_ack_due(&_receiver, frame, now)) [self ackFrame:frame at:now];
        }
    }
    if (_state == HBClientStopping && now >= _stopUntil) {
        _state = HBClientReady;
        [self publish:nil];
    }
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address withFilterContext:(id)filterContext {
    (void)filterContext;
    if (sock != _socket || _state == HBClientDisconnected || _state == HBClientDisconnecting) return;
    // Accept the configured camera IP even when images use a different source port.
    if (![[GCDAsyncUdpSocket hostFromAddress:address] isEqualToString:_deviceHost]) return;
    if ((_state != HBClientStarting && _state != HBClientStreaming) ||
        (_state == HBClientStarting && !_lastStart)) return;

    _seenDatagram = YES;
    HBFrame *frame = NULL;
    uint64_t now = HBNow();
    HBResult result = hb_receiver_feed(&_receiver, data.bytes, data.length, now, &frame);
    if (result == HB_INVALID) return;
    _seenFirstFragment = YES;
    if (result == HB_OLD || result == HB_NO_MEMORY) {
        HBFrame dropped = { .status = HB_ACK_DROP };
        hb_parse_fragment(data.bytes, data.length, &dropped.info);
        [self ackFrame:&dropped at:now];
        return;
    }
    if (result != HB_COMPLETE) return;

    [self ackFrame:frame at:now];
    if (frame->info.sequence > _lastQueuedFrame) {
        _lastQueuedFrame = frame->info.sequence;
        _lastFrame = now;
        _pendingJPEG = [NSData dataWithBytes:frame->bytes length:frame->info.frame_size];
    }
    hb_frame_release_payload(frame);
    [self decodeNextJPEG];
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error {
    if (sock != _socket) return;
    if (_state == HBClientDisconnecting) { [self closeSocket]; _state = HBClientDisconnected; [self publish:@"UDP 已断开，关闭图传指令发送失败"];
    } else [self fail:[NSString stringWithFormat:@"UDP 发送失败（%ld）：%@", tag, error.localizedDescription ?: @"未知错误"]];
}
- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)sock withError:(NSError *)error {
    if (sock != _socket) return;
    BOOL requested = _state == HBClientDisconnecting;
    [self fail:requested ? @"UDP 已断开" :
        [NSString stringWithFormat:@"UDP 已关闭：%@", error.localizedDescription ?: @"连接终止"]];
}
@end
