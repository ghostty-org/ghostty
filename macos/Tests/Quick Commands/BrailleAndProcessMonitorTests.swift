import Foundation
import Testing
@testable import Ghostty

struct BrailleAndProcessMonitorTests {
    @Test func brailleFramesValidity() {
        let styles: [BrailleProgressStyle] = [.spinner, .bar, .wave, .circle, .dots]
        for style in styles {
            let view = BrailleProgressBarView(style: style)
            #expect(!view.frames.isEmpty)
            for frame in view.frames {
                #expect(!frame.isEmpty)
                // Ensure frame contains Braille unicode characters
                let containsBraille = frame.unicodeScalars.contains { scalar in
                    (0x2800...0x28FF).contains(scalar.value)
                }
                #expect(containsBraille)
            }
        }
    }

    @Test func brailleBarConsistency() {
        let barView = BrailleProgressBarView(style: .bar)
        #expect(barView.frames.count == 8)
        let firstLen = barView.frames[0].count
        for frame in barView.frames {
            #expect(frame.count == firstLen) // Fixed character width ensures no UI fluttering
        }
    }

    @Test func terminalJobAIAgentDetection() {
        let agy = TerminalJob(pid: 100, name: "agy", commandLine: "agy --prompt 'hello'", pgid: 100, isForeground: true, state: .running)
        #expect(agy.isAIAgent)
        #expect(agy.aiAgentName == "AGY")
        #expect(!agy.isWaiting)

        let claude = TerminalJob(pid: 101, name: "claude", commandLine: "claude code", pgid: 101, isForeground: true, state: .waiting)
        #expect(claude.isAIAgent)
        #expect(claude.aiAgentName == "Claude")
        #expect(claude.isWaiting)

        let codex = TerminalJob(pid: 102, name: "codex", commandLine: "codex run", pgid: 102, isForeground: false, state: .running)
        #expect(codex.isAIAgent)
        #expect(codex.aiAgentName == "Codex")

        let ollama = TerminalJob(pid: 103, name: "ollama", commandLine: "ollama run llama3", pgid: 103, isForeground: false, state: .running)
        #expect(ollama.isAIAgent)
        #expect(ollama.aiAgentName == "Ollama")

        let normal = TerminalJob(pid: 104, name: "cargo", commandLine: "cargo build", pgid: 104, isForeground: true, state: .running)
        #expect(!normal.isAIAgent)
    }

    @Test func terminalJobSSHDetection() {
        let sshProd = TerminalJob(pid: 200, name: "ssh", commandLine: "ssh -i ~/.ssh/id_rsa prod-api-01", pgid: 200, isForeground: true, state: .running)
        #expect(sshProd.isSSH)
        #expect(sshProd.isProduction)
        #expect(sshProd.sshTarget == "prod-api-01")

        let sshDev = TerminalJob(pid: 201, name: "ssh", commandLine: "ssh dev-box.internal", pgid: 201, isForeground: true, state: .running)
        #expect(sshDev.isSSH)
        #expect(!sshDev.isProduction)
        #expect(sshDev.sshTarget == "dev-box.internal")
    }

    @Test func terminalJobStates() {
        let runningJob = TerminalJob(pid: 300, name: "make", commandLine: "make", pgid: 300, isForeground: true, state: .running)
        #expect(!runningJob.isWaiting)
        #expect(runningJob.state == .running)

        let waitingJob = TerminalJob(pid: 301, name: "sleep", commandLine: "sleep 100", pgid: 301, isForeground: true, state: .waiting)
        #expect(waitingJob.isWaiting)
        #expect(waitingJob.state == .waiting)

        let stoppedJob = TerminalJob(pid: 302, name: "vim", commandLine: "vim file.txt", pgid: 302, isForeground: false, state: .stopped)
        #expect(!stoppedJob.isWaiting)
        #expect(stoppedJob.state == .stopped)
    }

    @Test func brailleIdleRestingState() {
        let activeBar = BrailleProgressBarView(style: .bar, isAnimating: true)
        #expect(activeBar.isAnimating)

        let idleBar = BrailleProgressBarView(style: .bar, isAnimating: false)
        #expect(!idleBar.isAnimating)
        #expect(idleBar.idleFrame == "⣀⣀⣀⣀")

        let idleWave = BrailleProgressBarView(style: .wave, isAnimating: false)
        #expect(idleWave.idleFrame == "⡀⡀⡀⡀")
    }

    @Test func terminalJobThinkingVsIdle() {
        let thinkingAgent = TerminalJob(
            pid: 400,
            name: "agy",
            commandLine: "agy --prompt 'refactor'",
            pgid: 400,
            isForeground: true,
            state: .running,
            isThinking: true
        )
        #expect(thinkingAgent.isThinking)
        #expect(thinkingAgent.agentStatusText == "thinking")

        let idleAgent = TerminalJob(
            pid: 401,
            name: "agy",
            commandLine: "agy",
            pgid: 401,
            isForeground: true,
            state: .waiting,
            isThinking: false
        )
        #expect(!idleAgent.isThinking)
        #expect(idleAgent.agentStatusText == "idle")
    }
}
