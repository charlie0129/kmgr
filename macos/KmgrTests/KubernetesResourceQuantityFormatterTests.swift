import Testing
@testable import KmgrCore

@Suite("Kubernetes resource quantity formatting")
struct KubernetesResourceQuantityFormatterTests {
    @Test("CPU uses millicores below one core and compact cores above it")
    func cpu() {
        #expect(format(0, unit: "cores") == "0")
        #expect(format(0.42, unit: "cores") == "420m")
        #expect(format(0.0005, unit: "cores") == "0.5m")
        #expect(format(1.5, unit: "cores") == "1.5")
        #expect(format(23.256, unit: "cores") == "23.256")
    }

    @Test("byte resources choose readable Kubernetes binary units")
    func bytes() {
        #expect(format(512, unit: "bytes") == "512")
        #expect(format(8 * 1_024, unit: "bytes") == "8Ki")
        #expect(format(768 * 1_048_576, unit: "bytes") == "768Mi")
        #expect(format(17_576_384 * 1_024, unit: "bytes") == "16.76Gi")
        #expect(format(2 * 1_099_511_627_776, unit: "bytes") == "2Ti")
    }

    @Test("ephemeral storage and huge pages share byte presentation")
    func storageAndHugePages() {
        let ephemeralStorage = ResourceUsageValue(
            usage: 134_217_728_000,
            unit: "bytes",
            resourceName: "ephemeral-storage"
        )
        let hugePages = ResourceUsageValue(
            request: 131_072 * 1_024,
            unit: "bytes",
            resourceName: "hugepages-2Mi"
        )

        #expect(format(ephemeralStorage.usage!, unit: ephemeralStorage.unit) == "125Gi")
        #expect(format(hugePages.request!, unit: hugePages.unit) == "128Mi")
        #expect(hugePages.resourceName == "hugepages-2Mi")
    }

    @Test("generic resources retain numeric semantics and their external name")
    func genericResource() {
        let accelerator = ResourceUsageValue(
            request: 3,
            sortValue: 3,
            unit: "count",
            resourceName: "aliyun.com/ppu"
        )

        #expect(format(accelerator.request!, unit: accelerator.unit) == "3")
        #expect(accelerator.sortValue == 3)
        #expect(accelerator.resourceName == "aliyun.com/ppu")
        #expect(format(.infinity, unit: "bytes") == "Unavailable")
    }

    private func format(_ value: Double, unit: String) -> String {
        KubernetesResourceQuantityFormatter.compact(value, unit: unit)
    }
}
