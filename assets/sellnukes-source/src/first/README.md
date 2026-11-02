# src/first → ReplicatedFirst

Runs before anything else replicates. Owns the branded loading screen (B15, `LoadingScreen/`),
which hides once the client boot sets the `ClientBooted` player attribute.
