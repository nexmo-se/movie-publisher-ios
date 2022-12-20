# Movie Publisher 

This projects lets you publish an mp4 file in to a Vonage video session. User can also speak while the video is being played

1. Run "pod install" to install opentok dependencies
2. Edit ViewController.swift and add the kToken, kSessionId id and kApiKey
3. Run the app and join from Vonage Video playground to see the published stream.

## How it works

### VideoCapturer
1. This is a custom capturer implementing the video capture interface provided by video SDK. 
2. We get the video tracks from mp4 file, then get the video frame and feed to the SDK.
3. We use presentation time stamp provided by the decoder to synchronize audio and video

### CustomAudioDevice
1. This is a custom audio device implementing the audio interface provided by video SDK. 
2. Here we take the audio from microphone and mix with the audio coming from mp4 movie
3. The sampling rate for device is set to 48kHz and simulator is 44.1kHz. Refer to: https://tokbox.com/developer/sdks/ios/reference/Classes/OTAudioFormat.html for details.


This sample is tested with two sample mp4 files.

1. MP4 with audio at 48KHz and 5.1 audio
2. MP4 with audio at 44.1KHz and Stereo
