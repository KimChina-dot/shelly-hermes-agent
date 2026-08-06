# Shelly integration boundary

This directory is an integration template, not copied Shelly source. In a Shelly GPL-3.0 fork, implement `AndroidHostBindings` with its Expo native terminal module and scheduler, then pass the object to `createShellyHermesHost`. Do not import Shelly APIs into `src/core`.

Verified upstream: `RYOITABASHI/Shelly` commit `97271092e4d1c5b63556ab5296a9ed03c3c7766f`, v7.5.5. Actual native method names must be checked against that fork before wiring.
