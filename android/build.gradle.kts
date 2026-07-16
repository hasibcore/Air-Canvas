allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    
    afterEvaluate {
        if (project.plugins.hasPlugin("com.android.library") || project.plugins.hasPlugin("com.android.application")) {
            val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            android?.let {
                if (it.compileSdkVersion != null && (it.compileSdkVersion!!.contains("33") || it.compileSdkVersion!!.contains("32") || it.compileSdkVersion!!.contains("31") || it.compileSdkVersion!!.contains("30") || it.compileSdkVersion == "33" || it.compileSdkVersion == "32" || it.compileSdkVersion == "31")) {
                    it.compileSdkVersion("android-34")
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
