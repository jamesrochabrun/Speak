//
//  ConversationManager.swift
//  SpeakV2
//
//  Created by James Rochabrun on 11/9/25.
//

import Foundation
import Observation
import SwiftOpenAI
import AVFoundation

// Actor to safely share state between MainActor and RealtimeActor
actor ReadyState {
    var isReady = false

    func setReady(_ value: Bool) {
        isReady = value
    }
}

@Observable
@MainActor
final class ConversationManager {
    private(set) var isConnected = false
    private(set) var isListening = false
    private(set) var audioLevel: Float = 0.0
    private(set) var errorMessage: String?

    private var realtimeSession: OpenAIRealtimeSession?
    private var audioController: AudioController?
    private var sessionTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var audioLevelTimer: Timer?

    private let modelName = "gpt-4o-mini-realtime-preview-2024-12-17"

    func startConversation(apiKey: String) async {
        do {
            print("ConversationManager.startConversation - Starting...")

            // Request microphone permission
            let permissionGranted = await requestMicrophonePermission()
            guard permissionGranted else {
                errorMessage = "Microphone permission is required for voice mode"
                return
            }

            // Clean the API key
            let cleanApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

            // Create OpenAI service
            let service = OpenAIServiceFactory.service(apiKey: cleanApiKey)

            // Configure session
            let configuration = OpenAIRealtimeSessionConfiguration(
                inputAudioFormat: .pcm16,
                inputAudioTranscription: .init(model: "whisper-1"),
                instructions: "You are a helpful AI assistant. Have a natural conversation with the user.",
                maxResponseOutputTokens: .int(4096),
                modalities: [.audio, .text],
                outputAudioFormat: .pcm16,
                temperature: 0.7,
                turnDetection: .init(type: .semanticVAD(eagerness: .medium)),
                voice: "alloy"
            )

            // Create realtime session and audio controller on RealtimeActor
            print("Creating realtime session...")

            // Capture the session and controller from RealtimeActor context
            let sessionAndController: (OpenAIRealtimeSession, AudioController) = try await Task { @RealtimeActor in
                let session = try await service.realtimeSession(
                    model: modelName,
                    configuration: configuration
                )
                let audioController = try await AudioController(modes: [.playback, .record])
                return (session, audioController)
            }.value

            let session = sessionAndController.0
            let audioController = sessionAndController.1

            self.realtimeSession = session
            self.audioController = audioController

            // Start streaming microphone to OpenAI
            print("Starting microphone stream...")
            let readyState = ReadyState()

            micTask = Task { @RealtimeActor in
                do {
                    let micStream = try audioController.micStream()
                    for await buffer in micStream {
                        guard !Task.isCancelled else { break }

                        if await readyState.isReady,
                           let base64Audio = AudioUtils.base64EncodeAudioPCMBuffer(from: buffer) {
                            await session.sendMessage(
                                OpenAIRealtimeInputAudioBufferAppend(audio: base64Audio)
                            )
                        }
                    }
                } catch {
                    print("Microphone stream error: \(error)")
                    await MainActor.run {
                        self.errorMessage = "Microphone error: \(error.localizedDescription)"
                    }
                }
            }

            // Handle session messages
            print("Starting session message handler...")
            sessionTask = Task { @RealtimeActor in
                for await message in session.receiver {
                    guard !Task.isCancelled else { break }

                    await self.handleRealtimeMessage(
                        message,
                        session: session,
                        audioController: audioController,
                        readyState: readyState
                    )
                }
            }

            // Update connection state
            isConnected = true
            isListening = true
            startMonitoringAudioLevels()

            print("ConversationManager: Successfully started conversation")

        } catch {
            errorMessage = "Failed to start conversation: \(error.localizedDescription)"
            isConnected = false
            print("ConversationManager error: \(error)")
        }
    }

    @RealtimeActor
    private func handleRealtimeMessage(
        _ message: OpenAIRealtimeMessage,
        session: OpenAIRealtimeSession,
        audioController: AudioController,
        readyState: ReadyState
    ) async {
        switch message {
        case .error(let error):
            print("Realtime API Error: \(error ?? "Unknown error")")
            await MainActor.run {
                self.errorMessage = error ?? "Unknown error"
            }
            session.disconnect()

        case .sessionUpdated:
            print("Session updated - OpenAI is ready")
            // Optionally start AI speaking first
            await session.sendMessage(OpenAIRealtimeResponseCreate())

        case .responseCreated:
            print("Response created - Ready to receive audio")
            await readyState.setReady(true)

        case .responseAudioDelta(let base64Audio):
            // Play audio chunk from AI (audioController is @RealtimeActor isolated)
            audioController.playPCM16Audio(base64String: base64Audio)

        case .inputAudioBufferSpeechStarted:
            print("User started speaking - interrupting playback")
            audioController.interruptPlayback()

        case .responseTranscriptDone(let transcript):
            print("AI: \(transcript)")

        case .inputAudioTranscriptionCompleted(let transcript):
            print("User: \(transcript)")

        case .responseFunctionCallArgumentsDone(let name, let args, let callId):
            print("Function call: \(name)(\(args)) - callId: \(callId)")
            // Handle function calls here if needed

        case .sessionCreated:
            print("Session created")

        case .responseTranscriptDelta(let delta):
            print("AI transcript delta: \(delta)")

        case .inputAudioBufferTranscript(let transcript):
            print("Input audio transcript: \(transcript)")

        case .inputAudioTranscriptionDelta(let delta):
            print("User transcript delta: \(delta)")
        }
    }

    func stopConversation() {
        print("ConversationManager.stopConversation - Stopping...")

        stopMonitoringAudioLevels()

        // Cancel tasks
        sessionTask?.cancel()
        micTask?.cancel()
        sessionTask = nil
        micTask = nil

        // Stop audio controller and disconnect session on RealtimeActor
        let audioController = self.audioController
        let realtimeSession = self.realtimeSession

        Task { @RealtimeActor in
            audioController?.stop()
            realtimeSession?.disconnect()
        }

        self.audioController = nil
        self.realtimeSession = nil

        isConnected = false
        isListening = false
        audioLevel = 0.0
        errorMessage = nil

        print("ConversationManager: Conversation stopped")
    }

    private func requestMicrophonePermission() async -> Bool {
        print("Checking microphone permission...")

        #if os(macOS)
        let currentPermission = await AVAudioApplication.shared.recordPermission
        print("Current permission: \(currentPermission.rawValue)")

        if currentPermission == .granted {
            print("Microphone permission: already granted")
            return true
        }

        print("Requesting microphone permission...")
        let granted = await AVAudioApplication.requestRecordPermission()
        print("Microphone permission: \(granted ? "granted" : "denied")")
        return granted
        #else
        // iOS uses AVAudioSession
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            print("Microphone permission: already granted")
            return true
        case .denied:
            print("Microphone permission: denied")
            return false
        case .undetermined:
            print("Requesting microphone permission...")
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    print("Microphone permission: \(granted ? "granted" : "denied")")
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
        #endif
    }

    private func startMonitoringAudioLevels() {
        // Simulate audio levels for visualization
        // In a production app, you could extract actual audio levels from the PCM buffers
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                // Simulate varying audio levels
                self.audioLevel = Float.random(in: 0.0...1.0) * 0.3
            }
        }
    }

    private func stopMonitoringAudioLevels() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }
}
