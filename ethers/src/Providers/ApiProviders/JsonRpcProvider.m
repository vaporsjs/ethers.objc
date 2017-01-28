/**
 *  MIT License
 *
 *  Copyright (c) 2017 Richard Moore <me@ricmoo.com>
 *
 *  Permission is hereby granted, free of charge, to any person obtaining
 *  a copy of this software and associated documentation files (the
 *  "Software"), to deal in the Software without restriction, including
 *  without limitation the rights to use, copy, modify, merge, publish,
 *  distribute, sublicense, and/or sell copies of the Software, and to
 *  permit persons to whom the Software is furnished to do so, subject to
 *  the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included
 *  in all copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 *  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 *  THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 *  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 *  DEALINGS IN THE SOFTWARE.
 */

#import "JsonRpcProvider.h"

#import "NSData+Secure.h"

@interface Provider (private)

- (void)setBlockNumber: (NSInteger)blockNumber;

@end


#pragma mark -
#pragma mark - JsonRpcProvider

@interface JsonRpcProvider () {
    NSUInteger _requestCount;
    NSTimer *_poller;
}

@end


@implementation JsonRpcProvider

- (instancetype)initWithTestnet:(BOOL)testnet url:(NSURL *)url {
    self = [super initWithTestnet:testnet];
    if (self) {
        _url = url;
        [self doPoll];
    }
    return self;
}

- (void)dealloc {
    [_poller invalidate];
}

- (void)reset {
    [super reset];
    [self doPoll];
}


#pragma mark - Polling

- (void)doPoll {
    [[self getBlockNumber] onCompletion:^(IntegerPromise *promise) {
        if (promise.result) {
            [self setBlockNumber:promise.value];
        }
    }];
}

- (void)startPolling {
    if (self.polling) { return; }
    [super startPolling];
    _poller = [NSTimer scheduledTimerWithTimeInterval:4.0f target:self selector:@selector(doPoll) userInfo:nil repeats:YES];
}

- (void)stopPolling {
    if (!self.polling) { return; }
    [super stopPolling];
    [_poller invalidate];
    _poller = nil;
}


#pragma mark - Methods

- (id)sendMethod: (NSString*)method params: (NSObject*)params fetchType: (ApiProviderFetchType)fetchType {
    
    NSDictionary *request = @{
                              @"jsonrpc": @"2.0",
                              @"method": method,
                              @"id": @(42),
                              @"params": params,
                              };

    NSError *error = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
    
    if (error) {
        NSDictionary *userInfo = @{@"reason": @"invalid JSON values", @"error": error};
        return [Promise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:userInfo]];
    }

    NSObject* (^processResponse)(NSDictionary*) = ^NSObject*(NSDictionary *response) {
        NSDictionary *rpcError = [response objectForKey:@"error"];
        if (rpcError) {
            NSDictionary *userInfo = @{@"reason": [NSString stringWithFormat:@"%@", [rpcError objectForKey:@"message"]]};
            return [NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorBadResponse userInfo:userInfo];
        }

        NSObject *result = [response objectForKey:@"result"];
        if (!result) {
            NSDictionary *userInfo = @{@"reason": @"invalid result"};
            return [NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorBadResponse userInfo:userInfo];
        }
        
        return result; //coerceValue(result, fetchType);
    };
    
    return [self promiseFetchJSON:_url
                             body:body
                        fetchType:fetchType
                          process:processResponse];
}

- (BigNumberPromise*)getBalance:(Address *)address blockTag:(BlockTag)blockTag {
    NSObject *tag = getBlockTag(blockTag);
    
    if (!address || !tag ) {
        return [BigNumberPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }
    
    return [self sendMethod:@"eth_getBalance"
                     params:@[ address.checksumAddress, tag ]
                  fetchType:ApiProviderFetchTypeBigNumberHexString];
}

- (IntegerPromise*)getTransactionCount:(Address *)address blockTag:(BlockTag)blockTag {
    NSObject *tag = getBlockTag(blockTag);

    if (!address || !tag) {
        return [IntegerPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }
    
    return [self sendMethod:@"eth_getTransactionCount"
                     params:@[ address.checksumAddress, tag ]
                  fetchType:ApiProviderFetchTypeIntegerHexString];
}

- (IntegerPromise*)getBlockNumber {
    return [self sendMethod:@"eth_blockNumber" params:@[] fetchType:ApiProviderFetchTypeIntegerHexString];
}

- (BigNumberPromise*)getGasPrice {
    return [self sendMethod:@"eth_gasPrice" params:@[] fetchType:ApiProviderFetchTypeBigNumberHexString];
}

- (DataPromise*)call:(Transaction *)transaction {
    if (!transaction || !transaction.toAddress) {
        return [DataPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }
    
    return [self sendMethod:@"eth_call"
                     params:@[ transactionObject(transaction), @"latest" ]
                  fetchType:ApiProviderFetchTypeData];
}

- (BigNumberPromise*)estimateGas:(Transaction *)transaction {
    if (!transaction) {
        return [BigNumberPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }

    return [self sendMethod:@"eth_estimateGas"
                     params:@[ transactionObject(transaction), @"latest" ]
                  fetchType:ApiProviderFetchTypeBigNumberHexString];
}

- (HashPromise*)sendTransaction:(NSData *)signedTransaction {
    if (!signedTransaction) {
        return [HashPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }

    return [self sendMethod:@"eth_sendRawTransaction"
                     params:@[ [signedTransaction hexEncodedString] ]
                  fetchType:ApiProviderFetchTypeHash];
}

- (BlockInfoPromise*)getBlockByBlockTag:(BlockTag)blockTag {
    NSObject *blockTagName = getBlockTag(blockTag);
    if (!blockTagName) {
        return [BlockInfoPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }
    
    return [self sendMethod:@"eth_getBlockByNumber"
                     params:@[blockTagName, @(NO)]
                  fetchType:ApiProviderFetchTypeBlockInfo];
}

- (BlockInfoPromise*)getBlockByBlockHash:(Hash *)blockHash {
    if (!blockHash) {
        return [BlockInfoPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }
    
    return [self sendMethod:@"eth_getBlockByHash"
                     params:@[blockHash.hexString, @(NO)]
                  fetchType:ApiProviderFetchTypeBlockInfo];
}

- (TransactionInfoPromise*)getTransaction:(Hash *)transactionHash {
    if (!transactionHash) {
        return [TransactionInfoPromise rejected:[NSError errorWithDomain:ProviderErrorDomain code:ProviderErrorInvalidParameters userInfo:@{}]];
    }
    
    return [self sendMethod:@"eth_getTransactionByHash"
                     params:@[transactionHash.hexString]
                  fetchType:ApiProviderFetchTypeTransactionInfo];
}

#pragma mark - NSObject

- (NSString*)description {
    return [NSString stringWithFormat:@"<JsonRpcProvider tetnet=%@ url=%@>", (self.testnet ? @"YES": @"NO"), _url];
}

@end