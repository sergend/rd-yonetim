// swift-tools-version:5.10
// RD Yönetim çekirdeği: modeller, repository arayüzleri ve ViewModel'ler.
// RDCore hiçbir dış bağımlılık içermez; Linux'ta (GitHub Actions) derlenip test edilir.
// RDSupabase, repository arayüzlerinin Supabase uygulamasıdır.
import PackageDescription

let package = Package(
  name: "RDCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "RDCore", targets: ["RDCore"]),
    .library(name: "RDSupabase", targets: ["RDSupabase"]),
  ],
  dependencies: [
    .package(url: "https://github.com/supabase/supabase-swift.git", .upToNextMajor(from: "2.49.0")),
  ],
  targets: [
    .target(name: "RDCore"),
    .target(
      name: "RDSupabase",
      dependencies: ["RDCore", .product(name: "Supabase", package: "supabase-swift")]
    ),
    .testTarget(name: "RDCoreTests", dependencies: ["RDCore"]),
    .testTarget(name: "RDSupabaseIntegrationTests", dependencies: ["RDCore", "RDSupabase"]),
  ]
)
