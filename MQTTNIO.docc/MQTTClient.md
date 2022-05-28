# ``MQTTNIO/MQTTClient``

## Topics

### Creating a client

- ``init(host:port:identifier:eventLoopGroupProvider:logger:configuration:)``
- ``Configuration-swift.struct``

### Instance Properties

- ``configuration-swift.property``
- ``identifier``
- ``host``
- ``port``
- ``eventLoopGroup``
- ``logger``
- ``v5-swift.property``
- ``V5-swift.struct``

### Shutdown

- ``shutdown(queue:)``
- ``shutdown(queue:_:)``
- ``syncShutdownGracefully()``

### Connection

- ``connect(cleanSession:will:)-242j6``
- ``connect(cleanSession:will:)-51e4w``
- ``isActive()``
- ``disconnect()-8tgrs``
- ``disconnect()-45iy6``
- ``ping()-8mctk``
- ``ping()-3m8i5``

### Publish

- ``publish(to:payload:qos:retain:)``
- ``publish(to:payload:qos:retain:properties:)``

### Subscriptions

- ``subscribe(to:)-2ibiy``
- ``subscribe(to:)-1y95e``
- ``unsubscribe(from:)-48i9t``
- ``unsubscribe(from:)-1wjnz``
- ``createPublishListener()``
- ``addPublishListener(named:_:)``
- ``removePublishListener(named:)``

### Listeners

- ``addCloseListener(named:_:)``
- ``addShutdownListener(named:_:)``
- ``removeCloseListener(named:)``
- ``removeShutdownListener(named:)``
