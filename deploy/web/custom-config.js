
// ---- TalkChief Cowork Meetings (appended to the generated config.js) ----
config.defaultLogoUrl = 'images/talkchief-cowork-white.png';
config.disableDeepLinking = true;
config.deeplinking = { disabled: true, hideLogo: true };
config.disableThirdPartyRequests = true;
config.gravatar = { disabled: true };
config.analytics = { disabled: true };
config.feedbackPercentage = 0;
config.giphy = { enabled: false };
delete config.dropbox;
config.whiteboard = { enabled: false };
config.liveStreaming = { enabled: false };
config.fileRecordingsEnabled = false;
config.welcomePage = { disabled: true };
// Invitations, guests and scheduling are handled by Cowork, not the meeting UI.
config.disableInviteFunctions = true;
// Names come from the Cowork-issued token (members) or the guest join page.
config.readOnlyName = true;
config.disableProfile = true;
config.prejoinConfig = Object.assign({}, config.prejoinConfig, {
    enabled: true,
    hideExtraJoinButtons: [ 'no-audio', 'by-phone' ]
});
config.lobby = { autoKnock: true, enableChat: true };
config.securityUi = { hideLobbyButton: false, disableLobbyPassword: true };
// Keep peer-to-peer STUN on our own TURN host instead of the public Jitsi relay.
config.p2p = Object.assign({}, config.p2p, {
    stunServers: [ { urls: 'stun:turn.talkchief.io:3478' } ]
});
config.legalUrls = {
    helpCentre: 'https://talkchief.io/',
    privacy: 'https://talkchief.io/privacy-policy',
    terms: 'https://talkchief.io/terms-of-use',
    security: 'https://talkchief.io/'
};
config.deploymentUrls = {
    userDocumentationURL: 'https://talkchief.io/',
    downloadAppsUrl: 'https://talkchief.io/'
};
config.toolbarButtons = [
    'camera', 'chat', 'closedcaptions', 'desktop', 'filmstrip', 'fullscreen',
    'hangup', 'help', 'highlight', 'microphone', 'noisesuppression',
    'participants-pane', 'raisehand', 'reactions', 'security', 'select-background',
    'settings', 'shareaudio', 'stats', 'tileview', 'toggle-camera', 'videoquality',
    'breakout-rooms', 'polls', 'mute-everyone', 'mute-video-everyone'
];
// Brand theme (colours, backgrounds, logo) through Jitsi's dynamic-branding hook.
config.dynamicBrandingUrl = 'https://meet.talkchief.io/static/talkchief-branding.json';
// No username/password dialog: anyone without a Cowork token lands on a branded page.
config.tokenAuthUrl = 'https://meet.talkchief.io/static/talkchief-access.html?room={room}';
config.tokenAuthUrlAutoRedirect = true;
// Modern meeting-room layout (styles in branding/talkchief.css): the control
// bar stays put like in other meeting apps, and the top bar shows the meeting
// title, timer and participant count.
config.toolbarConfig = Object.assign({}, config.toolbarConfig, {
    alwaysVisible: true,
    autoHideWhileChatIsOpen: false
});
config.conferenceInfo = {
    alwaysVisible: [ 'recording', 'raised-hands-count', 'subject', 'conference-timer', 'participants-count' ],
    autoHide: []
};
