package dev.shelly.hermes.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class AgentProfilesTest {
    @Test
    fun `built in profiles define safe role boundaries`() {
        assertEquals(listOf("coding", "planner", "reviewer"), AgentProfiles.builtIns.map(AgentProfile::id))
        assertFalse(AgentProfiles.CODING.readOnly)
        assertTrue(AgentProfiles.PLANNER.readOnly)
        assertTrue(AgentProfiles.REVIEWER.readOnly)
        assertTrue("apply_patch" in AgentProfiles.CODING.toolNames)
        assertFalse("apply_patch" in AgentProfiles.PLANNER.toolNames)
        assertFalse("workspace.file.overwrite" in AgentProfiles.REVIEWER.allowedCapabilities)
    }

    @Test
    fun `profile validates identity prompt collections and limits`() {
        assertFailsWith<IllegalArgumentException> { profile(id = "Bad id") }
        assertFailsWith<IllegalArgumentException> { profile(name = " untrimmed") }
        assertFailsWith<IllegalArgumentException> { profile(systemPrompt = "") }
        assertFailsWith<IllegalArgumentException> { profile(capabilities = setOf("")) }
        assertFailsWith<IllegalArgumentException> { profile(tools = setOf(" read_file")) }
        assertFailsWith<IllegalArgumentException> {
            profile(limits = AgentLimits(maxRounds = 0))
        }
    }

    @Test
    fun `profile copies collections and does not expose mutation`() {
        val capabilities = linkedSetOf("workspace.file.read")
        val tools = linkedSetOf("read_file")
        val profile = profile(capabilities = capabilities, tools = tools)

        capabilities += "workspace.file.overwrite"
        tools += "overwrite_file"

        assertEquals(setOf("workspace.file.read"), profile.allowedCapabilities)
        assertEquals(setOf("read_file"), profile.toolNames)
        assertFailsWith<UnsupportedOperationException> {
            @Suppress("UNCHECKED_CAST")
            (profile.toolNames as MutableSet<String>) += "append_file"
        }
    }

    @Test
    fun `bundle uses intersection permissions and minimum limits`() {
        val coding = profile(
            id = "coding-custom",
            mode = AgentProfileMode.ACT,
            capabilities = setOf("workspace.file.read", "workspace.file.patch"),
            tools = setOf("read_file", "apply_patch"),
            limits = AgentLimits(20, 60_000, 30),
        )
        val planner = profile(
            id = "planner-custom",
            mode = AgentProfileMode.PLAN,
            capabilities = setOf("workspace.file.read", "workspace.tree.list"),
            tools = setOf("read_file", "list_files"),
            limits = AgentLimits(8, 20_000, 10),
        )
        val source = mutableListOf(coding, planner)
        val bundle = AgentBundle("custom", "Custom", source, planner.id)
        source.clear()

        assertEquals(listOf(coding, planner), bundle.profiles)
        assertSame(planner, bundle.defaultProfile)
        assertEquals(setOf("workspace.file.read"), bundle.allowedCapabilities)
        assertEquals(setOf("read_file"), bundle.toolNames)
        assertEquals(AgentLimits(8, 20_000, 10), bundle.limits)
        assertSame(coding, bundle.profile(coding.id))
        assertNull(bundle.profile("missing"))
    }

    @Test
    fun `bundle rejects missing default empty and duplicate profiles`() {
        val first = profile(id = "first")
        assertFailsWith<IllegalArgumentException> {
            AgentBundle("empty", "Empty", emptyList(), "first")
        }
        assertFailsWith<IllegalArgumentException> {
            AgentBundle("missing", "Missing", listOf(first), "other")
        }
        assertFailsWith<IllegalArgumentException> {
            AgentBundle("duplicate", "Duplicate", listOf(first, first), "first")
        }
    }

    @Test
    fun `registry includes built ins and rejects duplicate ids`() {
        val registry = AgentProfileRegistry()

        assertSame(AgentProfiles.CODING, registry.requireProfile("coding"))
        assertSame(AgentProfiles.STANDARD_BUNDLE, registry.requireBundle("standard"))
        assertEquals(3, registry.profiles().size)
        assertEquals(1, registry.bundles().size)

        val duplicateProfile = assertFailsWith<AgentProfileRegistryException> {
            registry.register(profile(id = "coding"))
        }
        assertEquals(AgentProfileRegistryErrorCode.PROFILE_ALREADY_REGISTERED, duplicateProfile.code)

        val duplicateBundle = assertFailsWith<AgentProfileRegistryException> {
            registry.register(AgentProfiles.STANDARD_BUNDLE)
        }
        assertEquals(AgentProfileRegistryErrorCode.BUNDLE_ALREADY_REGISTERED, duplicateBundle.code)
    }

    @Test
    fun `registry enforces registration order and typed missing errors`() {
        val registry = AgentProfileRegistry(emptyList(), emptyList())
        val custom = profile(id = "custom")
        val bundle = AgentBundle("custom-bundle", "Custom bundle", listOf(custom), custom.id)

        assertFailsWith<IllegalArgumentException> { registry.register(bundle) }
        registry.register(custom)
        assertSame(bundle, registry.register(bundle))
        assertSame(custom, registry.findProfile("custom"))
        assertSame(bundle, registry.findBundle("custom-bundle"))

        val missingProfile = assertFailsWith<AgentProfileRegistryException> {
            registry.requireProfile("missing")
        }
        assertEquals(AgentProfileRegistryErrorCode.PROFILE_NOT_FOUND, missingProfile.code)
        val missingBundle = assertFailsWith<AgentProfileRegistryException> {
            registry.requireBundle("missing")
        }
        assertEquals(AgentProfileRegistryErrorCode.BUNDLE_NOT_FOUND, missingBundle.code)
    }

    private fun profile(
        id: String = "test-profile",
        name: String = "Test profile",
        systemPrompt: String = "Test the requested behavior.",
        mode: AgentProfileMode = AgentProfileMode.REVIEW,
        capabilities: Set<String> = setOf("workspace.file.read"),
        limits: AgentLimits = AgentLimits(),
        tools: Set<String> = setOf("read_file"),
    ) = AgentProfile(id, name, systemPrompt, mode, capabilities, limits, tools)
}
