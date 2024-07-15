http-request ^https?:\/\/(?:[^\/]+\.)?9521732\.xyz(:\d+)?\/ header-del User-Agent
http-request ^https?:\/\/(?:[^\/]+\.)?9521732\.xyz(:\d+)?\/ header-add User-Agent "Emby"
http-request ^https?:\/\/(?:[^\/]+\.)?embyplus\.org(:\d+)?\/ header-del User-Agent
http-request ^https?:\/\/(?:[^\/]+\.)?embyplus\.org(:\d+)?\/ header-add User-Agent "Emby"
http-request ^https?:\/\/(?:[^\/]+\.)?chirsemby\.top(:\d+)?\/ header-del User-Agent
http-request ^https?:\/\/(?:[^\/]+\.)?chirsemby\.top(:\d+)?\/ header-add User-Agent "Emby"

[MITM]
hostname = 9521732.xyz, *.9521732.xyz, embyplus.org, *.embyplus.org, chirsemby.top, *.chirsemby.top
