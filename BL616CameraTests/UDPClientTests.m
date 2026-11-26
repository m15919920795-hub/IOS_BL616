#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
@import CocoaAsyncSocket;
#include <string.h>
#import "HBUDPClient.h"
#import "HBProtocol.h"
#import "JPEGRenderer.h"

@interface UDPClientTests : XCTestCase <HBUDPClientDelegate, GCDAsyncUdpSocketDelegate>
@property(nonatomic, strong) HBUDPClient *client;
@property(nonatomic, strong) GCDAsyncUdpSocket *server;
@property(nonatomic, strong) GCDAsyncUdpSocket *imageSender;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, XCTestExpectation *> *states;
@property(nonatomic, strong) XCTestExpectation *startReceived, *stopReceived, *frameReceived, *ackReceived;
@property(nonatomic, strong) XCTestExpectation *neutralAckReceived, *customAckReceived, *controlOffAckReceived;
@property(nonatomic) uint32_t neutralControlSequence;
@property(nonatomic, strong) NSData *fixture;
@property(nonatomic) uint16_t clientPort;
@property(nonatomic) BOOL sendFrame;
@property(nonatomic) BOOL sendMalformed;
@property(nonatomic) NSUInteger startCount;
@property(nonatomic) uint64_t frameSequence;
@property(nonatomic) HBClientState latestState;
@property(nonatomic) uint64_t latestGeneration;
@property(nonatomic, copy) NSString *lastMessage;
@end

@implementation UDPClientTests
- (void)setUp {
    [super setUp];
    self.states = [NSMutableDictionary dictionary];
    self.server = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    [self.server setIPv6Enabled:NO];
    NSError *error = nil;
    XCTAssertTrue([self.server bindToPort:0 error:&error], @"%@", error);
    XCTAssertTrue([self.server beginReceiving:&error], @"%@", error);
    self.client = [[HBUDPClient alloc] init]; self.client.delegate = self;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(8, 6) format:format];
    self.fixture = [renderer JPEGDataWithCompressionQuality:0.7 actions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blueColor setFill];
        [context fillRect:CGRectMake(0, 0, 8, 6)];
    }];
    XCTAssertGreaterThan(self.fixture.length, 0u);
    self.frameSequence = 1;
}
- (void)tearDown {
    self.client.delegate = nil; [self.client disconnect];
    self.server.delegate = nil; [self.server close];
    self.imageSender.delegate = nil; [self.imageSender close];
    self.client = nil; self.server = nil;
    self.imageSender = nil;
    [super tearDown];
}
- (XCTestExpectation *)expectState:(HBClientState)state {
    XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"state %ld",(long)state]];
    self.states[@(state)] = expectation; return expectation;
}
- (void)connect {
    XCTestExpectation *ready = [self expectState:HBClientReady];
    [self.client connectToHost:@"127.0.0.1" remotePort:self.server.localPort localPort:0];
    [self waitForExpectations:@[ready] timeout:3];
    XCTAssertNotEqual(self.clientPort, 0);
}
- (void)testStartReceiveAcknowledgeStopAndDisconnect {
    [self connect];
    self.startReceived = [self expectationWithDescription:@"START bytes received"];
    self.frameReceived = [self expectationWithDescription:@"UIImage delivered"];
    self.ackReceived = [self expectationWithDescription:@"complete ACK received"];
    self.sendFrame = YES;
    [self.client startVideo];
    [self waitForExpectations:@[self.startReceived,self.frameReceived,self.ackReceived] timeout:4];
    XCTAssertGreaterThanOrEqual(self.startCount, 1u);
    self.stopReceived = [self expectationWithDescription:@"STOP from same source port"];
    XCTestExpectation *ready = [self expectState:HBClientReady];
    [self.client stopVideo];
    [self waitForExpectations:@[self.stopReceived,ready] timeout:3];
    XCTestExpectation *closed = [self expectState:HBClientDisconnected];
    [self.client disconnect];
    [self waitForExpectations:@[closed] timeout:3];
    GCDAsyncUdpSocket *probe = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    [probe setIPv6Enabled:NO];
    NSError *error = nil;
    XCTAssertTrue([probe bindToPort:self.clientPort error:&error], @"Port not released: %@",error);
    [probe close];
}
- (void)testTXControlDataUpdatesAndStopsDuringPlayback {
    [self connect];
    const uint8_t custom[] = {0x33, 0xaa, 0x80, 0x00, 0x88};
    NSMutableData *payload = [NSMutableData dataWithBytes:custom length:sizeof(custom)];
    XCTAssertFalse([self.client setTXControlData:payload]);
    self.frameReceived = [self expectationWithDescription:@"UIImage delivered before TX control"];
    self.ackReceived = [self expectationWithDescription:@"standard ACK before enabling test"];
    self.sendFrame = YES;
    [self.client startVideo];
    [self waitForExpectations:@[self.frameReceived, self.ackReceived] timeout:4];

    self.neutralAckReceived = [self expectationWithDescription:@"two B ACKs carry neutral TX payloads"];
    const uint8_t neutral[] = {0x33, 0x80, 0x80, 0x00, 0x88};
    XCTAssertTrue([self.client setTXControlData:[NSData dataWithBytes:neutral length:sizeof(neutral)]]);
    [self waitForExpectations:@[self.neutralAckReceived] timeout:2];

    XCTAssertFalse([self.client setTXControlData:[NSData data]]);
    self.customAckReceived = [self expectationWithDescription:@"B ACK carries copied custom TX payload"];
    XCTAssertTrue([self.client setTXControlData:payload]);
    [payload resetBytesInRange:NSMakeRange(0, payload.length)];
    [self waitForExpectations:@[self.customAckReceived] timeout:2];

    self.controlOffAckReceived = [self expectationWithDescription:@"B ACK omits TX payload after stopping test"];
    XCTAssertTrue([self.client setTXControlData:nil]);
    [self waitForExpectations:@[self.controlOffAckReceived] timeout:2];
    XCTAssertEqual(self.latestState, HBClientStreaming);
}

- (void)testDisconnectCancelsPendingStart {
    [self connect];
    self.startReceived = [self expectationWithDescription:@"no delayed START"];
    self.startReceived.inverted = YES;
    XCTestExpectation *closed = [self expectState:HBClientDisconnected];
    [self.client startVideo]; [self.client disconnect];
    [self waitForExpectations:@[closed,self.startReceived] timeout:0.6];
}
- (void)testDifferentImageSourcePortAndNonInitialSequence {
    self.imageSender = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    [self.imageSender setIPv6Enabled:NO];
    NSError *error = nil;
    XCTAssertTrue([self.imageSender bindToPort:0 error:&error], @"%@", error);
    XCTAssertNotEqual(self.imageSender.localPort, self.server.localPort);
    self.frameSequence = 42;
    [self connect];
    self.startReceived = [self expectationWithDescription:@"START reaches command port"];
    self.frameReceived = [self expectationWithDescription:@"JPEG arrives from a separate image port, sequence 42"];
    self.ackReceived = [self expectationWithDescription:@"ACK reaches command port"];
    self.sendFrame = YES;
    [self.client startVideo];
    [self waitForExpectations:@[self.startReceived, self.frameReceived, self.ackReceived] timeout:4];
    XCTAssertEqual(self.latestState, HBClientStreaming);
}
- (void)testMalformedPacketReportsStartFailure {
    [self connect];
    self.sendMalformed = YES;
    self.frameReceived = [self expectationWithDescription:@"malformed data produces no image"];
    self.frameReceived.inverted = YES;
    XCTestExpectation *stopping = [self expectState:HBClientStopping];
    [self.client startVideo];
    [self waitForExpectations:@[stopping, self.frameReceived] timeout:6];
    XCTAssertTrue([self.lastMessage containsString:@"未识别出有效图像分片"]);
}
- (void)testInvalidAddressFailsLocally {
    XCTestExpectation *rejected = [self expectState:HBClientDisconnected];
    [self.client connectToHost:@"invalid-host" remotePort:8800 localPort:0];
    [self waitForExpectations:@[rejected] timeout:2];
}
- (void)testDecodeJPEGProducesUIImageAndRejectsMalformedData {
    UIImage *image = HBDecodeJPEG(self.fixture);
    XCTAssertNotNil(image);
    if (image) XCTAssertTrue(CGSizeEqualToSize(image.size, CGSizeMake(8, 6)));
    NSData *malformed = [NSData dataWithBytes:"\xff\xd8\xff\xd9" length:4];
    XCTAssertNil(HBDecodeJPEG(malformed));
}
- (void)client:(HBUDPClient *)client didUpdateState:(HBClientState)state
    generation:(uint64_t)generation localPort:(uint16_t)localPort message:(NSString *)message {
    (void)client;
    XCTAssertTrue(NSThread.isMainThread);
    self.latestState = state;
    self.latestGeneration = generation;
    self.lastMessage = message;
    if (state == HBClientReady) self.clientPort = localPort;
    XCTestExpectation *expectation = self.states[@(state)];
    if (expectation) {
        [self.states removeObjectForKey:@(state)];
        [expectation fulfill];
    }
}
- (void)client:(HBUDPClient *)client didReceiveImage:(UIImage *)image generation:(uint64_t)generation {
    (void)client;
    XCTAssertTrue(NSThread.isMainThread);
    XCTAssertEqual(generation, self.latestGeneration);
    XCTAssertEqual(self.latestState, HBClientStreaming);
    XCTAssertTrue(CGSizeEqualToSize(image.size, CGSizeMake(8, 6)));
    [self.frameReceived fulfill]; self.frameReceived = nil;
}
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address withFilterContext:(id)filterContext {
    (void)filterContext;
    const uint8_t *p = data.bytes;
    XCTAssertEqual([GCDAsyncUdpSocket portFromAddress:address], self.clientPort);
    if (data.length == 4 && memcmp(p,"\xef\x00\x04\x00",4) == 0) {
        XCTAssertEqual(sock, self.server);
        self.startCount++;
        [self.startReceived fulfill]; self.startReceived = nil;
        if (self.sendFrame) {
            NSUInteger count = (self.fixture.length + HB_FRAGMENT_SIZE - 1) / HB_FRAGMENT_SIZE;
            for (NSUInteger index = 0; index < count; index++) {
                NSUInteger offset = index * HB_FRAGMENT_SIZE;
                NSUInteger length = MIN(self.fixture.length - offset, HB_FRAGMENT_SIZE);
                NSMutableData *packet = [NSMutableData dataWithLength:HB_HEADER_SIZE + length];
                uint8_t *bytes = packet.mutableBytes;
                const uint8_t header[] = {0x93, 1, (uint8_t)packet.length, (uint8_t)(packet.length >> 8), 2, 2, 0, 1};
                memcpy(bytes, header, sizeof(header));
                for (unsigned i = 0; i < 8; i++) bytes[8 + i] = (uint8_t)(self.frameSequence >> (8 * i));
                for (unsigned i = 0; i < 4; i++) {
                    bytes[32 + i] = (uint8_t)(index >> (8 * i));
                    bytes[36 + i] = (uint8_t)(count >> (8 * i));
                    bytes[40 + i] = (uint8_t)(self.fixture.length >> (8 * i));
                }
                bytes[44] = 8;
                bytes[46] = 6;
                bytes[48] = 50;
                [self.fixture getBytes:bytes + HB_HEADER_SIZE range:NSMakeRange(offset, length)];
                [(self.imageSender ?: sock) sendData:packet toAddress:address withTimeout:1 tag:0];
            }
        } else if (self.sendMalformed) {
            NSData *malformed = [NSData dataWithBytes:"\xff\xd8\xff\xd9" length:4];
            [sock sendData:malformed toAddress:address withTimeout:1 tag:0];
        }
    } else if (data.length == 4 && memcmp(p,"\xef\x01\x04\x00",4) == 0) {
        [self.stopReceived fulfill]; self.stopReceived = nil;
    } else if (data.length == 124 && p[0] == 0xef && p[1] == 2) {
        XCTAssertEqual(sock, self.server);
        XCTAssertEqual(p[8], 2);
        XCTAssertEqual(p[88], self.frameSequence);
        XCTAssertEqual(p[96], 1);
        XCTAssertEqual(p[108], self.frameSequence + 1);
        XCTAssertEqual(p[116], 3);
        uint32_t controlSequence = 0;
        for (unsigned i = 0; i < 4; i++) controlSequence |= (uint32_t)p[12 + i] << (8 * i);
        XCTAssertEqual(controlSequence, self.neutralControlSequence + 1);
        if (p[16] == 5) {
            const uint8_t neutral[7] = {5, 0, 0x33, 0x80, 0x80, 0, 0x88};
            const uint8_t custom[7] = {5, 0, 0x33, 0xaa, 0x80, 0, 0x88};
            self.neutralControlSequence = controlSequence;
            if (memcmp(p + 16, neutral, sizeof(neutral)) == 0) {
                if (controlSequence == 2) {
                    [self.neutralAckReceived fulfill]; self.neutralAckReceived = nil;
                }
            } else {
                XCTAssertEqual(memcmp(p + 16, custom, sizeof(custom)), 0);
                [self.customAckReceived fulfill]; self.customAckReceived = nil;
            }
        } else {
            const uint8_t expected[10] = {8};
            XCTAssertEqual(memcmp(p + 16, expected, sizeof(expected)), 0);
            [self.controlOffAckReceived fulfill]; self.controlOffAckReceived = nil;
        }
    } else if (data.length == 48 && p[0] == 0xef && p[1] == 2 && p[8] == 1 && p[40] == 1) {
        XCTAssertEqual(sock, self.server);
        uint64_t sequence = 0;
        for (unsigned i = 0; i < 8; i++) sequence |= (uint64_t)p[32 + i] << (8 * i);
        XCTAssertEqual(sequence, self.frameSequence);
        [self.ackReceived fulfill]; self.ackReceived = nil;
    }
}
@end
