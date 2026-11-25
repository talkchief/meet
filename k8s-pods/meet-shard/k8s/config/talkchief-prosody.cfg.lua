-- TalkChief override of the Prosody configuration rendered by the image (stable-11248-2). The shard's
-- init container copies this file to Prosody's /config/conf.d/zz-talkchief.cfg.lua; the image copies
-- /config into its runtime configuration before rendering its own files, and prosody.cfg.lua ends
-- with Include "conf.d/*.cfg.lua", so this section is read after conf.d/jitsi-meet.cfg.lua and its
-- values win.
--
-- Bridge loss (L20): the video bridges log in on auth.meet.jitsi with stream management, and the
-- image keeps a dropped session there for smacks_hibernation_time = 15 seconds before the bridge leaves
-- the brewery room, which is what makes Jicofo move its conferences. On the test cluster
-- (2026-11-25) a powered-off bridge left the room 16 s after Prosody had already seen its connection
-- fail. One second: a bridge that is alive reconnects with a new session and rejoins the room; its
-- conferences have been moved by then, which is what a lost bridge needs anyway.
VirtualHost "auth.meet.jitsi"
    smacks_hibernation_time = 1
