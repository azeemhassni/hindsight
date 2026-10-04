import Foundation
import HindsightCore
import Testing
@testable import HindsightCoolify

/// The fixtures below are verbatim `docker inspect` output from a live Coolify
/// v4.3.23 install, trimmed to the fields Hindsight reads. They are the reason
/// these tests mean anything: the label set here is what Coolify really writes,
/// which is not what its source code or the brief suggested.
@Suite("Coolify label discovery")
struct CoolifyLabelDiscoveryTests {
    static let postgresInspect = """
    [{
      "Name": "/q78pdwdw3qpsm2zdmyqfu6wf",
      "State": { "Status": "running" },
      "Config": {
        "Image": "postgres:16-alpine",
        "Labels": {
          "com.docker.compose.project": "q78pdwdw3qpsm2zdmyqfu6wf",
          "com.docker.compose.project.working_dir": "/data/coolify/databases/q78pdwdw3qpsm2zdmyqfu6wf",
          "com.docker.compose.service": "q78pdwdw3qpsm2zdmyqfu6wf",
          "coolify.database.subType": "standalone-postgresql",
          "coolify.databaseId": "1",
          "coolify.environmentName": "production",
          "coolify.managed": "true",
          "coolify.projectName": "acme",
          "coolify.resourceName": "acme-db",
          "coolify.serviceName": "acme-db",
          "coolify.type": "database"
        }
      },
      "Mounts": [{
        "Type": "volume",
        "Name": "postgres-data-q78pdwdw3qpsm2zdmyqfu6wf",
        "Source": "/var/lib/docker/volumes/postgres-data-q78pdwdw3qpsm2zdmyqfu6wf/_data",
        "Destination": "/var/lib/postgresql/data"
      }]
    }]
    """

    @Test("finds a database resource and its real identity")
    func findsDatabaseResource() throws {
        let resources = try CoolifyLabelDiscovery.discover(inspectJSON: Self.postgresInspect)
        #expect(resources.count == 1)

        let resource = try #require(resources.first)
        // Identity comes from the compose project, because Coolify writes no
        // uuid label at all. Verified against v4.3.23.
        #expect(resource.uuid == "q78pdwdw3qpsm2zdmyqfu6wf")
        #expect(resource.kind == .database)
        #expect(resource.name == "acme-db")
        #expect(resource.projectName == "acme")
        #expect(resource.environmentName == "production")
        #expect(resource.subType == "standalone-postgresql")
        #expect(resource.databaseEngineName == "postgresql")
        #expect(resource.image == "postgres:16-alpine")
        #expect(resource.isRunning)
        #expect(resource.internalID == 1)
        #expect(resource.configurationDirectory == "/data/coolify/databases/q78pdwdw3qpsm2zdmyqfu6wf")
    }

    @Test("reads the volume and knows it is a named one")
    func readsVolume() throws {
        let resource = try #require(try CoolifyLabelDiscovery.discover(inspectJSON: Self.postgresInspect).first)
        #expect(resource.volumes.count == 1)

        let volume = try #require(resource.volumes.first)
        #expect(volume.name == "postgres-data-q78pdwdw3qpsm2zdmyqfu6wf")
        #expect(volume.mountPath == "/var/lib/postgresql/data")
        // A named volume, not a bind: that is what makes restoring into a
        // parallel volume possible.
        #expect(volume.isNamedVolume)
        #expect(volume.dataPath == "/var/lib/docker/volumes/postgres-data-q78pdwdw3qpsm2zdmyqfu6wf/_data")
    }

    @Test("tells a bind mount from a named volume")
    func distinguishesBindMounts() throws {
        let json = Self.postgresInspect
            .replacingOccurrences(of: "\"Type\": \"volume\"", with: "\"Type\": \"bind\"")
            .replacingOccurrences(
                of: "\"Name\": \"postgres-data-q78pdwdw3qpsm2zdmyqfu6wf\",",
                with: "\"Name\": \"\","
            )
            .replacingOccurrences(
                of: "\"Source\": \"/var/lib/docker/volumes/postgres-data-q78pdwdw3qpsm2zdmyqfu6wf/_data\"",
                with: "\"Source\": \"/srv/app-data\""
            )
        let resource = try #require(try CoolifyLabelDiscovery.discover(inspectJSON: json).first)
        let volume = try #require(resource.volumes.first)
        #expect(!volume.isNamedVolume)
        #expect(volume.hostPath == "/srv/app-data")
        #expect(volume.dataPath == "/srv/app-data")
    }

    @Test("ignores containers Coolify does not manage")
    func ignoresUnmanagedContainers() throws {
        let json = Self.postgresInspect.replacingOccurrences(
            of: "\"coolify.managed\": \"true\"",
            with: "\"coolify.managed\": \"false\""
        )
        #expect(try CoolifyLabelDiscovery.discover(inspectJSON: json).isEmpty)
    }

    @Test("falls back to the container name when the compose label is missing")
    func fallsBackToContainerName() throws {
        let json = Self.postgresInspect.replacingOccurrences(
            of: "\"com.docker.compose.project\": \"q78pdwdw3qpsm2zdmyqfu6wf\",",
            with: ""
        )
        let resource = try #require(try CoolifyLabelDiscovery.discover(inspectJSON: json).first)
        #expect(resource.uuid == "q78pdwdw3qpsm2zdmyqfu6wf")
    }

    @Test("recovers the resource kind from Coolify's working directory")
    func recoversKindFromPath() {
        #expect(
            CoolifyLabelDiscovery.kindFromWorkingDirectory("/data/coolify/applications/abc") == .application
        )
        #expect(CoolifyLabelDiscovery.kindFromWorkingDirectory("/data/coolify/services/abc") == .service)
        #expect(CoolifyLabelDiscovery.kindFromWorkingDirectory("/data/coolify/databases/abc") == .database)
        #expect(CoolifyLabelDiscovery.kindFromWorkingDirectory("/srv/other") == nil)
    }

    @Test("survives output with no Coolify containers at all")
    func survivesEmptyOutput() throws {
        #expect(try CoolifyLabelDiscovery.discover(inspectJSON: "[]").isEmpty)
        #expect(try CoolifyLabelDiscovery.parse(inspectJSON: "[]").isEmpty)
    }

    @Test("asks docker once rather than once per container")
    func inspectsInOneCall() {
        #expect(CoolifyLabelDiscovery.inspectCommand.contains("label=coolify.managed=true"))
        #expect(CoolifyLabelDiscovery.inspectCommand.contains("docker inspect $ids"))
    }
}

@Suite("Coolify tree")
struct CoolifyTreeTests {
    private func resource(
        _ uuid: String,
        project: String?,
        environment: String?,
        kind: CoolifyResourceKind = .application
    ) -> CoolifyResource {
        CoolifyResource(uuid: uuid, name: uuid, kind: kind, projectName: project, environmentName: environment)
    }

    @Test("groups resources into project and environment")
    func groupsResources() {
        let tree = CoolifyTree.assemble(
            [
                resource("a", project: "acme", environment: "production"),
                resource("b", project: "acme", environment: "staging"),
                resource("c", project: "beta", environment: "production"),
            ],
            source: .api
        )
        #expect(tree.projects.map(\.name) == ["acme", "beta"])
        #expect(tree.projects[0].environments.map(\.name) == ["production", "staging"])
        #expect(tree.allResources.count == 3)
        #expect(tree.resource(uuid: "b")?.environmentName == "staging")
    }

    @Test("keeps resources that name no project, rather than dropping them")
    func keepsUngroupedResources() {
        let tree = CoolifyTree.assemble(
            [resource("orphan", project: nil, environment: nil)],
            source: .containerLabels
        )
        #expect(tree.projects.map(\.name) == ["Ungrouped"])
        #expect(tree.projects[0].environments.map(\.name) == ["default"])
    }

    @Test("says where the tree came from, and what that costs")
    func explainsItsSource() {
        #expect(CoolifyTree.Source.api.explanation.contains("API"))
        // A label-only tree cannot see stopped resources, and a person looking
        // at it deserves to know that.
        #expect(CoolifyTree.Source.containerLabels.explanation.contains("not running"))
        #expect(CoolifyTree.Source.database.explanation.contains("private interface"))
    }
}

@Suite("Coolify instance plan")
struct CoolifyInstancePlanTests {
    @Test("captures the files a restore cannot do without")
    func capturesCriticalFiles() throws {
        let profile = try CoolifyInstancePlan.profile()
        #expect(profile.includePaths.contains("/data/coolify/source"))
        #expect(profile.includePaths.contains("/data/coolify/ssh"))
        #expect(profile.includePaths.contains("/data/coolify/proxy"))
        #expect(profile.includePaths.contains("/data/coolify/ssl"))
        // The environment file holds APP_KEY, without which every credential
        // in Coolify's database is undecryptable.
        #expect(CoolifyInstancePlan.requiredFiles.contains(CoolifyInstancePlan.environmentFile))
        #expect(CoolifyInstancePlan.environmentFile.hasPrefix("/data/coolify/source/"))
        // acme.json holds the Let's Encrypt account key and certificates.
        #expect(CoolifyInstancePlan.acmeFile.hasSuffix("acme.json"))
    }

    @Test("leaves out data that is regenerated and churns")
    func excludesRegeneratedData() throws {
        let profile = try CoolifyInstancePlan.profile()
        #expect(profile.excludePatterns.contains { $0.contains("metrics.sqlite") })
        #expect(profile.excludePatterns.contains { $0.contains("ssh/mux") })
        #expect(profile.excludePatterns.contains { $0.contains("installation-") })
    }

    @Test("dumps Coolify's own database as its own user")
    func dumpsCoolifyDatabase() {
        #expect(CoolifyInstancePlan.databaseDumpCommand.contains("docker exec coolify-db"))
        #expect(CoolifyInstancePlan.databaseDumpCommand.contains("--username=coolify"))
        #expect(CoolifyInstancePlan.databaseDumpCommand.contains("--dbname=coolify"))
        #expect(CoolifyInstancePlan.databaseDumpCommand.contains("--format=custom"))
    }

    @Test("detects the proxy rather than assuming one")
    func detectsProxyFlavour() {
        // A default v4.3.23 install runs Traefik, but Caddy is selectable.
        #expect(CoolifyProxyFlavour(proxyImage: "traefik:v3.6") == .traefik)
        #expect(CoolifyProxyFlavour(proxyImage: "caddy:2-alpine") == .caddy)
        #expect(CoolifyProxyFlavour(proxyImage: nil) == .none)
        #expect(CoolifyProxyFlavour(proxyImage: "") == .none)
        #expect(CoolifyProxyFlavour(proxyImage: "nginx:alpine") == .unknown)
        #expect(CoolifyProxyFlavour(proxyImage: "traefik:v3.6").dynamicConfigurationPath != nil)
    }
}
