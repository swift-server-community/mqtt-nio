# AWS IoT

Using MQTTNIO with AWS IoT.

## Overview

``MQTTConnection`` can be used to connect to AWS IoT brokers.
You can use both a WebSocket connection authenticated using AWS Signature V4 and a standard connection using a X.509 client certificate.
If you are using a X.509 certificate make sure you update the attached role to allow your client ID to connect and which topics you can subscribe, publish to.

If you are using an AWS Signature V4 authenticated WebSocket connection you can use the V4 signer from [Soto](https://github.com/soto-project/soto) to sign your initial request as follows

```swift
import SotoSignerV4

let host = "MY_AWS_IOT_ENDPOINT.iot.eu-west-1.amazonaws.com"
let headers = HTTPHeaders([("host", host)])
let signer = AWSSigner(
    credentials: StaticCredential(accessKeyId: "MYACCESSKEY", secretAccessKey: "MYSECRETKEY"),
    name: "iotdata",
    region: "eu-west-1"
)
let signedURL = signer.signURL(
    url: URL(string: "https://\(host)/mqtt")!,
    method: .GET,
    headers: headers,
    body: .none,
    expires: .minutes(30)
)
let requestURI = "/mqtt?\(signedURL.query!)"

try await MQTTConnection.withConnection(
    address: .hostname(host),
    configuration: .init(tls: .enable(...), webSocketConfiguration: .init(urlPath: requestURI)),
    identifier: "My AWS Client",
    logger: Logger(...)
) { connection in
    // You are now connected to AWS IoT
}
```
You can find out more about connecting to AWS brokers [here](https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html).
