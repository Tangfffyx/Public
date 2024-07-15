^https?:\/\/(9521732\.xyz|.*\.9521732\.xyz|embyplus\.org|.*\.embyplus\.org|chirsemby\.top|.*\.chirsemby\.top)\/ url request-header ^GET\s([^\s]+)\sHTTP\/1\.1\r\nHost:\s([^\r\n]+)\r\n.*User-Agent:.*\r\n request-header GET $1 HTTP/1.1\r\nUser-Agent: SenPlayer/4.0.9\r\nAccept: */*\r\nRange: bytes=31985-\r\nConnection: close\r\nHost: $2\r\nIcy-MetaData: 1\r\n

[MITM]
hostname = 9521732.xyz, *.9521732.xyz, embyplus.org, *.embyplus.org, chirsemby.top, *.chirsemby.top
