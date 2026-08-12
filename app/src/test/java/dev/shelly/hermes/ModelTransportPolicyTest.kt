package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelTransportPolicyTest {
    @Test fun retryStatusIsLimitedToRateLimitsAndServerErrors() {
        val policy = ModelRetryPolicy()
        assertTrue(policy.isRetryableStatus(429))
        assertTrue(policy.isRetryableStatus(500))
        assertTrue(policy.isRetryableStatus(599))
        assertFalse(policy.isRetryableStatus(400))
        assertFalse(policy.isRetryableStatus(401))
        assertFalse(policy.isRetryableStatus(403))
        assertFalse(policy.isRetryableStatus(404))
    }

    @Test fun delayUsesBoundedExponentialBackoff() {
        val policy = ModelRetryPolicy(initialDelayMs = 250, maxDelayMs = 1_000)
        assertEquals(250, policy.delayBeforeRetry(0))
        assertEquals(500, policy.delayBeforeRetry(1))
        assertEquals(1_000, policy.delayBeforeRetry(2))
        assertEquals(1_000, policy.delayBeforeRetry(8))
    }

    @Test fun retryFailureExcludesAuthenticationAndBadRequests() {
        val policy = ModelRetryPolicy()
        assertTrue(policy.isRetryableFailure(ModelGatewayException.Network("offline")))
        assertTrue(policy.isRetryableFailure(ModelGatewayException.Timeout("slow")))
        assertFalse(policy.isRetryableFailure(ModelGatewayException.Timeout("HTTP timeout", httpStatus = 408)))
        assertTrue(policy.isRetryableFailure(ModelGatewayException.Timeout("gateway timeout", httpStatus = 504)))
        assertTrue(policy.isRetryableFailure(ModelGatewayException.RateLimited("busy", 429)))
        assertTrue(policy.isRetryableFailure(ModelGatewayException.Upstream("down", 503)))
        assertFalse(policy.isRetryableFailure(ModelGatewayException.Upstream("redirect", 302)))
        assertFalse(policy.isRetryableFailure(ModelGatewayException.Authentication("bad key", 401)))
        assertFalse(policy.isRetryableFailure(ModelGatewayException.InvalidRequest("bad", httpStatus = 400)))
        assertFalse(policy.isRetryableFailure(ModelGatewayException.Cancelled("cancelled")))
    }
}
