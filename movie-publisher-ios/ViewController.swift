//
//  ViewController.swift
//  movie-publisher-ios
//
//  Created by iujie on 24/11/2022.
//

import UIKit
import OpenTok

// Replace with your OpenTok API key
let kApiKey = "47565621"
// Replace with your generated session ID
let kSessionId = "1_MX40NzU2NTYyMX5-MTY2OTYyNDQ1MTkyMH5XdllCaFIvdjc4T0x6TTE5b0RJd2JERTV-fg"
// Replace with your generated token
let kToken = "T1==cGFydG5lcl9pZD00NzU2NTYyMSZzaWc9NDQxMjE5NjFiNTIzMDI3MjFjNGIyY2RhZDZlM2YxN2U0MjExMmQ5YTpzZXNzaW9uX2lkPTFfTVg0ME56VTJOVFl5TVg1LU1UWTJPVFl5TkRRMU1Ua3lNSDVYZGxsQ2FGSXZkamM0VDB4NlRURTViMFJKZDJKRVJUVi1mZyZjcmVhdGVfdGltZT0xNjY5NjI0NDkwJm5vbmNlPTAuMTI4MzAwMTUyODMxMTAyMyZyb2xlPXB1Ymxpc2hlciZleHBpcmVfdGltZT0xNjcwMjI5Mjg5JmluaXRpYWxfbGF5b3V0X2NsYXNzX2xpc3Q9"


let kWidgetHeight = 240
let kWidgetWidth = 320
let screenSize: CGRect = UIScreen.main.bounds;
let screenWidth = screenSize.width;
let screenHeight = screenSize.height;

class ViewController: UIViewController {
    lazy var session: OTSession = {
        return OTSession(apiKey: kApiKey, sessionId: kSessionId, delegate: self)!
    }()

    var publisher: OTPublisher?
    var subscriber: OTSubscriber?
    var capturer: VideoCapturer?
    var videoLoaded: AVAsset?
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        videoLoaded = loadVideoFromDocumentDirectory(fileName: "vonage-video")
        doConnect()
    }
    
    /**
     * Asynchronously begins the session connect process. Some time later, we will
     * expect a delegate method to call us back with the results of this action.
     */
    private func doConnect() {
        var error: OTError?
        defer {
            process(error: error)
        }
        session.connect(withToken: kToken, error: &error)
    }
    
    /**
     * Sets up an instance of OTPublisher to use with this session. OTPubilsher
     * binds to the device camera and microphone, and will provide A/V streams
     * to the OpenTok session.
     */
    fileprivate func doPublish() {
        var error: OTError? = nil
        defer {
            process(error: error)
        }
        let settings = OTPublisherSettings()
        settings.name = UIDevice.current.name
        publisher = OTPublisher(delegate: self, settings: settings)
        publisher?.audioFallbackEnabled = false

        capturer = VideoCapturer(video: videoLoaded!)
        publisher?.videoCapture = capturer

        session.publish(publisher!, error: &error)
    }
    
    fileprivate func doSubscribe(_ stream: OTStream) {
        var error: OTError?
        defer {
            process(error: error)
        }
        subscriber = OTSubscriber(stream: stream, delegate: self)
        
        session.subscribe(subscriber!, error: &error)
    }
    
    fileprivate func process(error err: OTError?) {
        if let e = err {
            showAlert(errorStr: e.localizedDescription)
        }
    }
    
    fileprivate func showAlert(errorStr err: String) {
        DispatchQueue.main.async {
            let controller = UIAlertController(title: "Error", message: err, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: "Ok", style: .default, handler: nil))
            self.present(controller, animated: true, completion: nil)
        }
    }
    fileprivate func loadVideoFromDocumentDirectory(fileName: String) -> AVAsset? {
    
       if let path = Bundle.main.path(forResource:fileName, ofType: "mp4", inDirectory: "") {
           let fileUrl = URL.init(fileURLWithPath: path)
           return AVAsset(url: fileUrl)
       }

       return nil
   }
    
}

extension ViewController: OTSessionDelegate {
    func sessionDidConnect(_ session: OTSession) {
        print("Session connected")
        doPublish()
    }
    
    func sessionDidDisconnect(_ session: OTSession) {
        print("Session disconnected")
    }
    
    func session(_ session: OTSession, streamCreated stream: OTStream) {
        print("Session streamCreated: \(stream.streamId)")
        doSubscribe(stream)
    }
    
    func session(_ session: OTSession, streamDestroyed stream: OTStream) {
        print("Session streamDestroyed: \(stream.streamId)")
    }
    
    func session(_ session: OTSession, didFailWithError error: OTError) {
        print("session Failed to connect: \(error.localizedDescription)")
    }
}

// MARK: - OTPublisher delegate callbacks
extension ViewController: OTPublisherDelegate {
    func publisher(_ publisher: OTPublisherKit, streamCreated stream: OTStream) {
    }
    
    func publisher(_ publisher: OTPublisherKit, streamDestroyed stream: OTStream) {
    }
    
    func publisher(_ publisher: OTPublisherKit, didFailWithError error: OTError) {
        print("Publisher failed: \(error.localizedDescription)")
    }
}

// MARK: - OTSubscriber delegate callbacks
extension ViewController: OTSubscriberDelegate {
    func subscriberDidConnect(toStream subscriberKit: OTSubscriberKit) {
        if let subsView = subscriber?.view {
            subsView.frame = CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight)
            view.addSubview(subsView)
            view.sendSubviewToBack(subsView);
        }
    }

    func subscriber(_ subscriber: OTSubscriberKit, didFailWithError error: OTError) {
        print("Subscriber failed: \(error.localizedDescription)")
    }

    func subscriberVideoDataReceived(_ subscriber: OTSubscriber) {
    }
}