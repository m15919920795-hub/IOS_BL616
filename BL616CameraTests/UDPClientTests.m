#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
@import CocoaAsyncSocket;
#include <string.h>
#import "HBUDPClient.h"
#import "JPEGRenderer.h"

@interface UDPClientTests : XCTestCase <HBUDPClientDelegate, GCDAsyncUdpSocketDelegate>
@property(nonatomic, strong) HBUDPClient *client;
@property(nonatomic, strong) GCDAsyncUdpSocket *server;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, XCTestExpectation *> *states;
@property(nonatomic, strong) XCTestExpectation *startReceived, *stopReceived, *frameReceived, *ackReceived;
@property(nonatomic, strong) NSData *fixture;
@property(nonatomic) uint16_t clientPort;
@property(nonatomic) BOOL sendFrame;
@property(nonatomic) NSUInteger startCount;
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
    self.fixture = [NSData dataWithBytes:"\xff\xd8\xff\xd9" length:4];
}
- (void)tearDown {
    self.client.delegate = nil; [self.client disconnect];
    self.server.delegate = nil; [self.server close];
    self.client = nil; self.server = nil;
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
    self.frameReceived = [self expectationWithDescription:@"JPEG reassembled"];
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
- (void)testDisconnectCancelsPendingStart {
    [self connect];
    self.startReceived = [self expectationWithDescription:@"no delayed START"];
    self.startReceived.inverted = YES;
    XCTestExpectation *closed = [self expectState:HBClientDisconnected];
    [self.client startVideo]; [self.client disconnect];
    [self waitForExpectations:@[closed,self.startReceived] timeout:0.6];
}
- (void)testInvalidAddressFailsLocally {
    XCTestExpectation *rejected = [self expectState:HBClientDisconnected];
    [self.client connectToHost:@"invalid-host" remotePort:8800 localPort:0];
    [self waitForExpectations:@[rejected] timeout:2];
}
- (void)testJPEGRendererDecodesAndClearsOnStop {
    UIImageView *view = [[UIImageView alloc] init];
    JPEGRenderer *renderer = [[JPEGRenderer alloc] initWithImageView:view];
    UIGraphicsImageRenderer *imageRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(16,16)];
    UIImage *image = [imageRenderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blueColor setFill]; [context fillRect:CGRectMake(0,0,16,16)];
    }];
    [renderer resetForGeneration:1];
    [renderer submitJPEG:UIImageJPEGRepresentation(image,0.7) generation:1];
    XCTestExpectation *displayed = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
            (void)object; (void)bindings; return view.image != nil;
        }] object:nil];
    [self waitForExpectations:@[displayed] timeout:3];
    [renderer resetForGeneration:2]; XCTAssertNil(view.image);
    [renderer submitJPEG:UIImageJPEGRepresentation(image,0.7) generation:1];
    XCTAssertNil(view.image);
}
- (void)client:(HBUDPClient *)client didUpdateStatus:(NSDictionary<NSString *,id> *)status {
    (void)client;
    NSNumber *state = status[@"state"];
    if ([state integerValue] == HBClientReady) self.clientPort = [status[@"localPort"] unsignedShortValue];
    XCTestExpectation *expectation = self.states[state];
    if (expectation) { [self.states removeObjectForKey:state]; [expectation fulfill]; }
}
- (void)client:(HBUDPClient *)client didReceiveJPEG:(NSData *)jpeg generation:(uint64_t)generation {
    (void)client; (void)generation;
    XCTAssertEqualObjects(jpeg,self.fixture);
    [self.frameReceived fulfill]; self.frameReceived = nil;
}
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address withFilterContext:(id)filterContext {
    (void)filterContext;
    const uint8_t *p = data.bytes;
    XCTAssertEqual([GCDAsyncUdpSocket portFromAddress:address], self.clientPort);
    if (data.length == 4 && memcmp(p,"\xef\x00\x04\x00",4) == 0) {
        self.startCount++;
        [self.startReceived fulfill]; self.startReceived = nil;
        if (self.sendFrame) {
            uint8_t packet[60] = {0x93,1,60,0,2,2,0,1,1};
            packet[36] = 1; packet[40] = 4; packet[44] = 1; packet[46] = 1; packet[48] = 50;
            memcpy(packet + 56,self.fixture.bytes,4);
            [sock sendData:[NSData dataWithBytes:packet length:60] toAddress:address withTimeout:1 tag:0];
        }
    } else if (data.length == 4 && memcmp(p,"\xef\x01\x04\x00",4) == 0) {
        [self.stopReceived fulfill]; self.stopReceived = nil;
    } else if (data.length == 48 && p[0] == 0xef && p[1] == 2 && p[8] == 1 && p[32] == 1 && p[40] == 1) {
        [self.ackReceived fulfill]; self.ackReceived = nil;
    }
}
@end
