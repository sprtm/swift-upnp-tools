//
// UPnPControlPoint.swift
// 

import Foundation
import SwiftHttpServer

/**
 UPnP ControlPoint Delegate
 */
public protocol UPnPControlPointDelegate {
    /**
     On Device Added
     */
    func onDeviceAdded(device: UPnPDevice)
    /**
     On Device Removed
     */
    func onDeviceRemoved(device: UPnPDevice)
}


/**
 UPnP Control Point Implementation
 */
public class UPnPControlPoint : UPnPDeviceBuilderDelegate, HttpRequestHandler {

    /**
     scpdHandler
     - Parameter device
     - Parameter service
     - Parameter scpd
     - Parameter error
     */
    public typealias scpdHandler = ((UPnPDevice?, UPnPService?, UPnPScpd?, Error?) -> Void)

    /**
     is running
     */
    public var running: Bool {
        get {
            return _running
        }
    }
    var _running: Bool = false

    /**
     is suspended
     */
    public var suspended: Bool {
        get {
            return _suspended
        }
    }
    var _suspended: Bool = false
    

    /**
     http server bind hostname
     */
    public var hostname: String?

    /**
     http server bind port
     */
    public var port: Int

    /**
     http server
     */
    public var httpServer : HttpServer?

    /**
     ssdp receiver
     */
    public var ssdpReceiver : SSDPReceiver?

    /**
     devices
     */
    public var devices = [String:UPnPDevice]()

    /**
     delegate
     */
    var delegate: UPnPControlPointDelegate?

    /**
     event subscribers
     */
    var eventSubscribers = [UPnPEventSubscriber]()
    
    /**
     event property handlers
     */
    var notificationHandlers = [UPnPEventSubscriber.eventNotificationHandler]()

    /**
     on device added handlers
     */
    var onDeviceAddedHandlers = [(UPnPDevice) -> Void]()

    /**
     on device removed handlers
     */
    var onDeviceRemovedHandlers = [(UPnPDevice) -> Void]()

    /**
     on scpd handlers
     */
    var onScpdHandlers = [scpdHandler]()

    /**
     timer
     */
    var timer: DispatchSourceTimer?

    /**
     lock queue
     */
    let lockQueue = DispatchQueue(label: "com.tjapp.swiftUPnPControlPoint.lockQueue")
    
    public init(httpServerBindHostname: String? = nil, httpServerBindPort: Int = 0) {
        if httpServerBindHostname == nil {
            self.hostname = Network.getInetAddress()?.hostname
        } else {
            self.hostname = httpServerBindHostname
        }
        self.port = httpServerBindPort
    }

    deinit {
        finish()
    }

    /**
     Start UPnP Control Point
     */
    public func run() throws {

        if _running {
            print("UPnPControlPoint::run() - aready running")
            return
        }

        _running = true
        _suspended = false
        startHttpServer()
        startSsdpReceiver()
        try startTimer()
    }

    /**
     Stop UPnP Control Point
     */
    public func finish() {
        timer?.cancel()
        httpServer?.finish()
        ssdpReceiver?.finish()

        devices.removeAll()
        delegate = nil
        for subscriber in eventSubscribers {
            unsubscribe(subscriber: subscriber)
        }
        eventSubscribers.removeAll()
        notificationHandlers.removeAll()
        onDeviceAddedHandlers.removeAll()
        onDeviceRemovedHandlers.removeAll()
        onScpdHandlers.removeAll()

        _running = false
    }

    /**
     suspend
     */
    public func suspend() {

        if _suspended {
            // already suspended
            return
        }
        _suspended = true
        timer?.cancel()
        httpServer?.finish()
        ssdpReceiver?.finish()
        for subscriber in eventSubscribers {
            subscriber.unsubscribe()
        }
    }

    /**
     resume
     */
    public func resume() throws {

        if !_suspended || !_running {
            // already suspended or not running
            return
        }
        _suspended = false
        startHttpServer {
            (httpServer, error) in
            let subscribers = self.eventSubscribers
            self.eventSubscribers = [UPnPEventSubscriber]()
            for subscriber in subscribers {
                self.subscribe(udn: subscriber.udn, service: subscriber.service)
            }
        }
        startSsdpReceiver()
        try startTimer()
    }

    /**
     Get device with UDN
     */
    public func getDevice(udn: String) -> UPnPDevice? {
        return devices[udn]
    }

    /**
     add notification handler
     */
    public func addNotificationHandler(notificationHandler: UPnPEventSubscriber.eventNotificationHandler?) {
        guard let notificationHandler = notificationHandler else {
            return
        }
        notificationHandlers.append(notificationHandler)
    }

    /**
     Start HTTP Server
     */
    public func startHttpServer(readyHandler: ((HttpServer, Error?) -> Void)? = nil) {

        guard httpServer == nil else {
            print("UPnPControlPoint::startHttpServer() already started")
            // already started
            return
        }
        
        DispatchQueue.global(qos: .default).async {

            do {
                self.httpServer = HttpServer(hostname: self.hostname, port: self.port)
                guard let httpServer = self.httpServer else {
                    throw UPnPError.custom(string: "UPnPControlPoint::startHttpServer() error - http server start failed")
                }
                try httpServer.route(pattern: "/notify/**", handler: self)
                try httpServer.run(readyHandler: readyHandler)
            } catch let error{
                print("UPnPControlPoint::startHttpServer() error - error - \(error)")
            }
            self.httpServer = nil
        }
    }

    /**
     when http request header completed
     */
    public func onHeaderCompleted(header: HttpHeader, request: HttpRequest, response: HttpResponse) throws {
    }

    /**
     when http request body completed
     */
    public func onBodyCompleted(body: Data?, request: HttpRequest, response: HttpResponse) throws {
        guard let sid = request.header["sid"] else {
            let err = HttpServerError.illegalArgument(string: "No SID")
            handleEventProperties(subscriber: nil, properties: nil, error: err)
            throw err
        }

        guard let subscriber = getEventSubscriber(sid: sid) else {
            let err = HttpServerError.illegalArgument(string: "No subscbier found with SID: '\(sid)'")
            handleEventProperties(subscriber: nil, properties: nil, error: err)
            throw err
        }

        guard let data = body else {
            let err = HttpServerError.illegalArgument(string: "No Content")
            handleEventProperties(subscriber: subscriber, properties: nil, error: err)
            throw err
        }

        guard let xmlString = String(data: data, encoding: .utf8) else {
            let err = HttpServerError.illegalArgument(string: "Wrong XML String")
            handleEventProperties(subscriber: subscriber, properties: nil, error: err)
            throw err
        }

        guard let properties = UPnPEventProperties.read(xmlString: xmlString) else {
            let err = HttpServerError.custom(string: "Parse Failed Event Properties")
            handleEventProperties(subscriber: subscriber, properties: nil, error: err)
            throw err
        }
        
        handleEventProperties(subscriber: subscriber, properties: properties, error: nil)
        response.setStatus(code: 200)
    }

    func handleEventProperties(subscriber: UPnPEventSubscriber?, properties: UPnPEventProperties?, error: Error?) {
        for notificationHandler in notificationHandlers {
            notificationHandler(subscriber, properties, error)
        }
        subscriber?.handleNotification(properties: properties, error: error)
    }

    /**
     Start SSDP Receiver
     */
    public func startSsdpReceiver() {

        guard ssdpReceiver == nil else {
            print("UPnPControlPoint::startSsdpReceiver() already started")
            return
        }

        DispatchQueue.global(qos: .default).async {
            do {
                self.ssdpReceiver = try SSDPReceiver() {
                    (address, ssdpHeader) in
                    guard let ssdpHeader = ssdpHeader else {
                        return nil
                    }
                    return self.onSSDPHeader(address: address, ssdpHeader: ssdpHeader)
                }
                try self.ssdpReceiver?.run()
            } catch let error {
                print("UPnPControlPoint::startSsdpReceiver() error - error - \(error)")
            }
            self.ssdpReceiver = nil
        }
    }

    func startTimer() throws {
        let queue = DispatchQueue(label: "com.tjapp.upnp.timer")
        timer = DispatchSource.makeTimerSource(queue: queue)
        guard let timer = timer else {
            throw UPnPError.custom(string: "Failed DispatchSource.makeTimerSource")
        }
        timer.schedule(deadline: .now(), repeating: 10.0, leeway: .seconds(0))
        timer.setEventHandler { () in
            self.lockQueue.sync {
                self.removeExpiredDevices()
                self.removeExpiredSubscriber()
            }
        }
        timer.resume()
    }

    /**
     Send M-SEARCH with ST (Service Type) and MX (Max)
     */
    public func sendMsearch(st: String, mx: Int, ssdpHandler: SSDP.ssdpHandler? = nil) {

        DispatchQueue.global(qos: .default).async {

            SSDP.sendMsearch(st: st, mx: mx) {
                (address, ssdpHeader) in
                guard let ssdpHeader = ssdpHeader else {
                    return
                }
                self.onSSDPHeader(address: address, ssdpHeader: ssdpHeader)
                ssdpHandler?(address, ssdpHeader)
            }
        }
    }

    /**
     On SSDP Header is received
     */
    @discardableResult public func onSSDPHeader(address: (String, Int32)?, ssdpHeader: SSDPHeader) -> [SSDPHeader]? {
        if ssdpHeader.isNotify {
            guard let nts = ssdpHeader.nts else {
                return nil
            }
            switch nts {
            case .alive:
                guard let usn = ssdpHeader.usn else {
                    break
                }
                if let device = self.devices[usn.uuid] {
                    device.renewTimeout()
                } else if let location = ssdpHeader["LOCATION"] {
                    if let url = URL(string: location) {
                        devices[usn.uuid] = UPnPDevice(timeout: 15)
                        buildDevice(url: url)
                    }
                }
                break
            case .byebye:
                if let usn = ssdpHeader.usn {
                    self.removeDevice(udn: usn.uuid)
                }
                break
            case .update:
                if let usn = ssdpHeader.usn {
                    if let device = self.devices[usn.uuid] {
                        device.renewTimeout()
                    }
                }
                break
            }
        } else if ssdpHeader.isHttpResponse {
            guard let usn = ssdpHeader.usn else {
                return nil
            }
            if let device = self.devices[usn.uuid] {
                device.renewTimeout()
            } else if let location = ssdpHeader["LOCATION"] {
                if let url = URL(string: location) {
                    devices[usn.uuid] = UPnPDevice(timeout: 15)
                    buildDevice(url: url)
                }
            }
        }
        return nil
    }

    func buildDevice(url: URL) {
        UPnPDeviceBuilder(delegate: self) {
            (device, service, scpd, error) in 
            for handler in self.onScpdHandlers {
                handler(device, service, scpd, error)
            }
        }.build(url: url)
    }

    /**
     On Device Build with URL and Device
     */
    public func onDeviceBuild(url: URL?, device: UPnPDevice?) {
        guard let device = device else {
            return
        }
        addDevice(device: device)
    }

    /**
     On Device Build Error
     */
    public func onDeviceBuildError(error: String?) {
        print("[UPnPControlPoint] Device Build Error - \(error ?? "nil")")
    }

    /**
     Add Handler: On Device Added
     */
    public func onDeviceAdded(handler: ((UPnPDevice) -> Void)?) {
        guard let handler = handler else {
            return
        }
        onDeviceAddedHandlers.append(handler)
    }

    /**
     Add Handler: On Device Removed
     */
    public func onDeviceRemoved(handler: ((UPnPDevice) -> Void)?) {
        guard let handler = handler else {
            return
        }
        onDeviceRemovedHandlers.append(handler)
    }

    /**
     Add Handler: On Scpd
     */
    func onScpd(handler: (scpdHandler)?) {
        guard let handler = handler else {
            return
        }
        onScpdHandlers.append(handler)
    }

    /**
     Add device with Device
     */
    public func addDevice(device: UPnPDevice) {
        guard let udn = device.udn else {
            return
        }
        devices[udn] = device
        delegate?.onDeviceAdded(device: device)
        for handler in onDeviceAddedHandlers {
            handler(device)
        }
    }

    /**
     Remove Device with UDN
     */
    public func removeDevice(udn: String) {
        guard let device = devices[udn] else {
            return
        }
        delegate?.onDeviceRemoved(device: device)
        for handler in onDeviceRemovedHandlers {
            handler(device)
        }
        if let udn = device.udn {
            for subscriber in getEventSubscribers(forUdn: udn) {
                unsubscribe(subscriber: subscriber)
            }
        }

        devices[udn] = nil
    }

    /**
     Invoek with Service and actionRequest
     */
    public func invoke(service: UPnPService, actionRequest: UPnPActionRequest, completionHandler: (UPnPActionInvoke.invokeCompletionHandler)?) {
        return self.invoke(service: service, actionName: actionRequest.actionName, fields: actionRequest.fields, completionHandler: completionHandler);
    }

    /**
     Invoke with Service and action, properties, completionHandler (Optional)
     */
    public func invoke(service: UPnPService, actionName: String, fields: OrderedProperties, completionHandler: (UPnPActionInvoke.invokeCompletionHandler)?) {
        guard let serviceType = service.serviceType else {
            print("UPnPControlPoint::invoke() error - no service type")
            return
        }
        let soapRequest = UPnPSoapRequest(serviceType: serviceType, actionName: actionName)
        for field in fields.fields {
            soapRequest[field.key] = field.value
        }
        guard let controlUrl = service.controlUrl, let device = service.device else {
            print("UPnPControlPoint::invoke() error - no control url or no device")
            return
        }
        guard let url = URL(string: controlUrl, relativeTo: device.rootDevice.baseUrl) else {
            print("UPnPControlPoint::invoke() error - url failed")
            return
        }
        UPnPActionInvoke(url: url, soapRequest: soapRequest, completionHandler: completionHandler).invoke()
    }

    /**
     Subscribe with service
     */
    @discardableResult public func subscribe(udn: String, service: UPnPService, completionHandler: (UPnPEventSubscriber.subscribeCompletionHandler)? = nil) -> UPnPEventSubscriber? {
        guard let callbackUrls = makeCallbackUrl(udn: udn, service: service) else {
            print("UPnPControlPoint::subscribe() error - makeCallbackUrl failed")
            return nil
        }
        guard let subscriber = UPnPEventSubscriber(udn: udn, service: service, callbackUrls: [callbackUrls]) else {
            print("UPnPControlPoint::subscribe() error - UPnPEventSubscriber initializer failed")
            return nil
        }
        subscriber.subscribe {
            (subscriber, error) in

            completionHandler?(subscriber, error)

            guard error == nil else {
                return
            }
            guard let subscriber = subscriber else {
                return
            }
            self.eventSubscribers.append(subscriber)
        }
        return subscriber
    }

    /**
     unsubscribe event with sid
     */
    public func unsubscribe(sid: String, completionHandler: UPnPEventSubscriber.unsubscribeCompletionHandler? = nil) -> Void {
        guard let subscriber = getEventSubscriber(sid: sid) else {
            print("UPnPControlPoint::unsubscribe() error - event subscriber not found (sid: '\(sid)')")
            return
        }
        unsubscribe(subscriber: subscriber, completionHandler: completionHandler)
    }

    /**
     unsubscribe event with subscriber
     */
    public func unsubscribe(subscriber: UPnPEventSubscriber, completionHandler: UPnPEventSubscriber.unsubscribeCompletionHandler? = nil) {
        subscriber.unsubscribe(completionHandler: completionHandler)
        lockQueue.sync {
            eventSubscribers.removeAll(where: { $0.sid == subscriber.sid })
        }
    }

    /**
     Get Event Subscriber with sid (subscription id)
     */
    public func getEventSubscriber(sid: String) -> UPnPEventSubscriber? {
        for subscriber in eventSubscribers {
            guard let subscriber_sid = subscriber.sid else {
                continue
            }
            if subscriber_sid == sid {
                return subscriber
            }
        }
        return nil
    }

    /**
     Get Event Subscribers for UDN
     */
    public func getEventSubscribers(forUdn udn: String) -> [UPnPEventSubscriber] {
        var ret = [UPnPEventSubscriber]()
        for subscriber in eventSubscribers {
            if subscriber.udn == udn {
                ret.append(subscriber)
            }
        }
        return ret
    }

    /**
     Get Event Subscribers for UDN and Service Id
     */
    public func getEventSubscribers(forUdn udn: String, forServiceId serviceId: String) -> [UPnPEventSubscriber] {
        var ret = [UPnPEventSubscriber]()
        for subscriber in eventSubscribers {
            if subscriber.udn == udn && subscriber.service.serviceId == serviceId {
                ret.append(subscriber)
            }
        }
        return ret
    }

    /**
     Get Event Subscribers for Service Id
     */
    public func getEventSubscribers(forServiceId serviceId: String) -> [UPnPEventSubscriber] {
        var ret = [UPnPEventSubscriber]()
        for subscriber in eventSubscribers {
            if subscriber.service.serviceId == serviceId {
                ret.append(subscriber)
            }
        }
        return ret
    }

    func removeExpiredDevices() {
        devices = devices.filter { $1.isExpired == false }
    }

    func removeExpiredSubscriber() {
        eventSubscribers = eventSubscribers.filter { $0.isExpired == false }
    }

    func makeCallbackUrl(udn: String, service: UPnPService) -> URL? {
        guard let httpServer = self.httpServer else {
            return nil
        }
        guard let httpServerAddress = httpServer.serverAddress else {
            return nil
        }
        guard let addr = Network.getInetAddress() else {
            return nil
        }
        let hostname = addr.hostname
        return UPnPCallbackUrl.make(hostname: hostname, port: httpServerAddress.port, udn: udn, serviceId: service.serviceId ?? "nil")
    }
}
