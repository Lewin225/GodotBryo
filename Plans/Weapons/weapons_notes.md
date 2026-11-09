# Weapons notes

Not planned work. Comes after VR.

## Co-op

- The peer with authority over an actor runs its weapon node and sends fire requests; the host's
  ProjectileServer resolves hits and damage and sends the result.
- The fire request (`fire(weapon base, shooter, muzzle transform, aim point, seed)`) is the
  replicated message. The aim point is taken on the peer with authority: the host has no client
  camera. A timestamp is added then.
- Every peer plays the cosmetic fire (flash, sound, clip, tracer, projectile flight) when a
  request arrives. The shooter's client predicts its own hits; the host's result confirms them.
- No anti-cheat: the console is enabled in co-op, so cheating is up to the group.
