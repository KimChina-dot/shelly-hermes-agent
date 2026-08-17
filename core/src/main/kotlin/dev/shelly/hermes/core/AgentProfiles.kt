package dev.shelly.hermes.core

import java.util.Collections

enum class AgentProfileMode(val readOnly: Boolean) {
    ACT(readOnly = false),
    PLAN(readOnly = true),
    REVIEW(readOnly = true),
}

/** Immutable policy and prompt configuration for one agent role. */
class AgentProfile(
    val id: String,
    val name: String,
    val systemPrompt: String,
    val mode: AgentProfileMode,
    allowedCapabilities: Set<String>,
    val limits: AgentLimits,
    toolNames: Set<String>,
) {
    val allowedCapabilities: Set<String> = immutableSet(allowedCapabilities)
    val toolNames: Set<String> = immutableSet(toolNames)
    val readOnly: Boolean get() = mode.readOnly

    init {
        requireValidId(id, "Agent profile")
        requireTrimmed(name, "Agent profile name")
        requireTrimmed(systemPrompt, "Agent profile systemPrompt")
        validateEntries(allowedCapabilities, "Agent profile capability")
        validateEntries(toolNames, "Agent profile tool name")
        validateLimits(limits, "Agent profile")
    }

    override fun toString(): String = "AgentProfile(id='$id', name='$name', mode=$mode)"
}

/**
 * A bundle groups roles that can cooperate on one task.
 *
 * Its capability and tool sets use intersection semantics. They are therefore a
 * safe shared envelope and can never grant a role access that the role itself
 * does not have. Per-role access remains available from [profiles].
 */
class AgentBundle(
    val id: String,
    val name: String,
    profiles: List<AgentProfile>,
    val defaultProfileId: String,
) {
    val profiles: List<AgentProfile> = immutableList(profiles)
    val defaultProfile: AgentProfile
    val allowedCapabilities: Set<String>
    val toolNames: Set<String>
    val limits: AgentLimits

    init {
        requireValidId(id, "Agent bundle")
        requireTrimmed(name, "Agent bundle name")
        require(profiles.isNotEmpty()) { "Agent bundle must contain at least one profile" }
        val duplicateIds = profiles.groupingBy { it.id }.eachCount().filterValues { it > 1 }.keys
        require(duplicateIds.isEmpty()) { "Agent bundle contains duplicate profile ids: $duplicateIds" }
        requireValidId(defaultProfileId, "Default profile")
        defaultProfile = this.profiles.firstOrNull { it.id == defaultProfileId }
            ?: throw IllegalArgumentException(
                "Default profile '$defaultProfileId' is not part of agent bundle '$id'",
            )
        allowedCapabilities = intersect(this.profiles.map(AgentProfile::allowedCapabilities))
        toolNames = intersect(this.profiles.map(AgentProfile::toolNames))
        limits = AgentLimits(
            maxRounds = this.profiles.minOf { it.limits.maxRounds },
            maxTokens = this.profiles.minOf { it.limits.maxTokens },
            maxToolCalls = this.profiles.minOf { it.limits.maxToolCalls },
        )
    }

    fun profile(id: String): AgentProfile? = profiles.firstOrNull { it.id == id }

    override fun toString(): String = "AgentBundle(id='$id', profiles=${profiles.map(AgentProfile::id)})"
}

enum class AgentProfileRegistryErrorCode {
    PROFILE_ALREADY_REGISTERED,
    BUNDLE_ALREADY_REGISTERED,
    PROFILE_NOT_FOUND,
    BUNDLE_NOT_FOUND,
}

class AgentProfileRegistryException(
    message: String,
    val code: AgentProfileRegistryErrorCode,
    val resourceId: String,
) : IllegalStateException(message)

/** Thread-safe in-memory registry for selectable agent profiles and bundles. */
class AgentProfileRegistry(
    profiles: Iterable<AgentProfile>,
    bundles: Iterable<AgentBundle> = emptyList(),
) {
    private val profilesById = linkedMapOf<String, AgentProfile>()
    private val bundlesById = linkedMapOf<String, AgentBundle>()

    constructor() : this(AgentProfiles.builtIns, listOf(AgentProfiles.STANDARD_BUNDLE))

    init {
        profiles.forEach(::register)
        bundles.forEach(::register)
    }

    fun register(profile: AgentProfile): AgentProfile = synchronized(this) {
        if (profilesById.containsKey(profile.id)) {
            throw AgentProfileRegistryException(
                "Agent profile '${profile.id}' is already registered",
                AgentProfileRegistryErrorCode.PROFILE_ALREADY_REGISTERED,
                profile.id,
            )
        }
        profilesById[profile.id] = profile
        profile
    }

    fun register(bundle: AgentBundle): AgentBundle = synchronized(this) {
        if (bundlesById.containsKey(bundle.id)) {
            throw AgentProfileRegistryException(
                "Agent bundle '${bundle.id}' is already registered",
                AgentProfileRegistryErrorCode.BUNDLE_ALREADY_REGISTERED,
                bundle.id,
            )
        }
        val missingProfiles = bundle.profiles.map(AgentProfile::id).filterNot(profilesById::containsKey)
        require(missingProfiles.isEmpty()) {
            "Agent bundle '${bundle.id}' references unregistered profiles: $missingProfiles"
        }
        bundlesById[bundle.id] = bundle
        bundle
    }

    fun findProfile(id: String): AgentProfile? = synchronized(this) { profilesById[id] }

    fun requireProfile(id: String): AgentProfile = findProfile(id)
        ?: throw AgentProfileRegistryException(
            "Agent profile '$id' is not registered",
            AgentProfileRegistryErrorCode.PROFILE_NOT_FOUND,
            id,
        )

    fun findBundle(id: String): AgentBundle? = synchronized(this) { bundlesById[id] }

    fun requireBundle(id: String): AgentBundle = findBundle(id)
        ?: throw AgentProfileRegistryException(
            "Agent bundle '$id' is not registered",
            AgentProfileRegistryErrorCode.BUNDLE_NOT_FOUND,
            id,
        )

    fun profiles(): List<AgentProfile> = synchronized(this) { profilesById.values.toList() }

    fun bundles(): List<AgentBundle> = synchronized(this) { bundlesById.values.toList() }
}

object AgentProfiles {
    private val readCapabilities = setOf(
        "workspace.file.read",
        "workspace.path.inspect",
        "workspace.tree.list",
        "workspace.text.search",
    )
    private val readTools = setOf("read_file", "exists", "list_files", "search_files")

    val CODING = AgentProfile(
        id = "coding",
        name = "Coding",
        systemPrompt = "Inspect the workspace, implement the requested change, verify it, and report concrete results.",
        mode = AgentProfileMode.ACT,
        allowedCapabilities = readCapabilities + setOf(
            "workspace.file.patch",
            "workspace.file.create",
            "workspace.file.overwrite",
            "workspace.file.append",
        ),
        limits = AgentLimits(),
        toolNames = readTools + setOf("apply_patch", "create_file", "overwrite_file", "append_file"),
    )

    val PLANNER = AgentProfile(
        id = "planner",
        name = "Planner",
        systemPrompt = "Analyze the request and workspace, then produce a precise implementation plan without modifying files.",
        mode = AgentProfileMode.PLAN,
        allowedCapabilities = readCapabilities,
        limits = AgentLimits(maxRounds = 10, maxTokens = 32_000, maxToolCalls = 20),
        toolNames = readTools,
    )

    val REVIEWER = AgentProfile(
        id = "reviewer",
        name = "Reviewer",
        systemPrompt = "Review the implementation for correctness, regressions, security risks, and missing tests without modifying files.",
        mode = AgentProfileMode.REVIEW,
        allowedCapabilities = readCapabilities,
        limits = AgentLimits(maxRounds = 12, maxTokens = 48_000, maxToolCalls = 24),
        toolNames = readTools,
    )

    val builtIns: List<AgentProfile> = immutableList(listOf(CODING, PLANNER, REVIEWER))

    val STANDARD_BUNDLE = AgentBundle(
        id = "standard",
        name = "Standard development",
        profiles = builtIns,
        defaultProfileId = CODING.id,
    )
}

private val VALID_ID = Regex("[a-z][a-z0-9._-]{0,63}")

private fun requireValidId(value: String, owner: String) {
    require(VALID_ID.matches(value)) {
        "$owner id must match ${VALID_ID.pattern}"
    }
}

private fun requireTrimmed(value: String, field: String) {
    require(value.isNotBlank() && value == value.trim()) { "$field must be non-blank and trimmed" }
}

private fun validateEntries(values: Set<String>, field: String) {
    values.forEach { requireTrimmed(it, field) }
}

private fun validateLimits(limits: AgentLimits, owner: String) {
    require(limits.maxRounds > 0) { "$owner maxRounds must be positive" }
    require(limits.maxTokens > 0) { "$owner maxTokens must be positive" }
    require(limits.maxToolCalls > 0) { "$owner maxToolCalls must be positive" }
}

private fun intersect(sets: List<Set<String>>): Set<String> {
    val result = sets.first().toMutableSet()
    sets.drop(1).forEach { result.retainAll(it) }
    return immutableSet(result)
}

private fun <T> immutableSet(values: Collection<T>): Set<T> =
    Collections.unmodifiableSet(LinkedHashSet(values))

private fun <T> immutableList(values: Collection<T>): List<T> =
    Collections.unmodifiableList(ArrayList(values))
