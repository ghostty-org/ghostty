import Foundation

struct GitCommitID: Hashable, Sendable, Equatable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    var shortSHA: String {
        String(rawValue.prefix(8))
    }
}

/// A repository has one execution endpoint. It cannot carry a local target
/// alongside SSH credentials, nor an incomplete host-only remote fallback.
enum GitExecutionTarget: Hashable, Sendable {
    case local
    case ssh(GitSSHConnection)

    init(session: PaneSessionContext) throws {
        switch session.state {
        case .local: self = .local
        case .sshReady: self = .ssh(try GitSSHConnection(session: session))
        case .sshConnecting: throw GitExecutionError.executionFailed(GitL10n.text("The SSH session is not ready."))
        }
    }

    var sshConnection: GitSSHConnection? {
        if case .ssh(let connection) = self { return connection }
        return nil
    }

    var executor: any GitExecutor {
        switch self {
        case .local: LocalGitExecutor()
        case .ssh(let connection): SSHGitExecutor(connection: connection)
        }
    }
}

struct GitRepositoryIdentity: Hashable, Sendable {
    let target: GitExecutionTarget
    let worktreePath: String
    let gitDirPath: String
    let commonGitDirPath: String

    var sshConnection: GitSSHConnection? { target.sshConnection }
    var executor: any GitExecutor { target.executor }

    var stateKey: String {
        switch target {
        case .local: worktreePath
        case .ssh(let connection): "ssh\0" + connection.identity + "\0" + worktreePath
        }
    }

    func matches(_ session: PaneSessionContext) -> Bool {
        (try? GitExecutionTarget(session: session)) == target
    }

    var repositoryName: String {
        let name = WorkspacePathPresentation.folderName(worktreePath)
        return name.isEmpty ? worktreePath : name
    }

    init(target: GitExecutionTarget = .local, worktreePath: String,
         gitDirPath: String, commonGitDirPath: String) {
        self.target = target
        self.worktreePath = worktreePath
        self.gitDirPath = gitDirPath
        self.commonGitDirPath = commonGitDirPath
    }
}

enum GitRepositoryStatusKind: Equatable, Sendable {
    case notRepository(directory: String)
    case unborn(repository: GitRepositoryIdentity, branch: String)
    case detached(repository: GitRepositoryIdentity, commitID: GitCommitID)
    case ready(repository: GitRepositoryIdentity, branch: String, headCommitID: GitCommitID?)
    case ssh(host: String, workingDirectory: String)
    case error(title: String, message: String)

    var repository: GitRepositoryIdentity? {
        switch self {
        case .unborn(let repo, _),
             .detached(let repo, _),
             .ready(let repo, _, _):
            repo
        case .notRepository, .ssh, .error:
            nil
        }
    }

    var headDescription: String? {
        switch self {
        case .ready(_, let branch, _):
            branch
        case .unborn(_, let branch):
            GitL10n.format("{0} (initial)", String(describing: branch))
        case .detached(_, let commitID):
            GitL10n.format("detached at {0}", String(describing: commitID.shortSHA))
        case .notRepository, .ssh, .error:
            nil
        }
    }
}
