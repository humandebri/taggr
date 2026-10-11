pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "TAGGR"

include(":app")

// Resolve the actively maintained sibling fork directly, including its transitive dependencies.
val ic4jAgent = file("../../ic4j-agent").canonicalFile
includeBuild(ic4jAgent)

includeBuild(ic4jAgent.resolve("android"))
