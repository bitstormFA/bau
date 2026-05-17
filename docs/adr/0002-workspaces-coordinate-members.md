# Treat workspaces as coordination roots

Bau workspaces use a root manifest to select members and provide shared defaults, but the workspace root is not implicitly the same buildable unit as a member project. We decided to model the workspace as a coordination root and each included project as a workspace member, leaving any future "root as member" behavior explicit rather than assumed.
