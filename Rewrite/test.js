^https?:\/\/(9521732\.xyz|.*\.9521732\.xyz|embyplus\.org|.*\.embyplus\.org|chirsemby\.top|.*\.chirsemby\.top)\/ url request-header (\r\n)X-Emby-Authorization:.+Client="VidHub_iOS",.+(\r\n) request-header $1X-Emby-Authorization: Emby UserId="5cafd4642e844414892fd340562d66a3", Client="SenPlayer", Device="iPad", DeviceId="3A32255D-B2EA-40B9-BD1C-D58592B77BC8", Version="1.7.2"$2
^https?:\/\/(9521732\.xyz|.*\.9521732\.xyz|embyplus\.org|.*\.embyplus\.org|chirsemby\.top|.*\.chirsemby\.top)\/ url request-header (\r\n)User-Agent:.+(\r\n) request-header $1User-Agent: SenPlayer/1.7.2$2

[MITM]
hostname = 9521732.xyz, *.9521732.xyz, embyplus.org, *.embyplus.org, chirsemby.top, *.chirsemby.top
