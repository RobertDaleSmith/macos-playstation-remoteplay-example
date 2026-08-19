import Foundation

/// Static key material used by the Remote Play protocol (registration, session auth, stream HMAC).
///
/// These tables are taken unchanged from chiaki (AGPL-3.0) and pyremoteplay (GPL-3.0), down to
/// their names — `HMAC_KEY_PS4` here is byte for byte the one in pyremoteplay's `keys.py`. They are
/// the single clearest reason this project is AGPL-3.0 rather than something permissive.
///
/// Stored base64 so the compiler doesn't have to type-check multi-kilobyte array literals.
enum RPKeys {
    /// HMAC_KEY_PS4 (16 bytes)
    static let hmacKeyPs4: [UInt8] = decode(
        "INZvWQTqfBTlV//FLkiKyA=="
    )

    /// HMAC_KEY_PS5 (16 bytes)
    static let hmacKeyPs5: [UInt8] = decode(
        "RkaHs0nKjOhZxScPXXpp1g=="
    )

    /// REG_KEY_0_PS4 (512 bytes)
    static let regKey0Ps4: [UInt8] = decode(
        "vs5d8MF9tdDLMBNdqlYj+8S88Y84V/vU1D8mOLXO7WohvDjQHmjMe0XRvkIaCKoW/bDA9No16RL9IQdINMH8n4y2y12ynITg"
            + "Gvqgx+s6k7Oz8RWvE70hq+pbgFBrMR18HUC6PFYO55Q6W6FAgHQKrSjPR99CpmnpXrvAwA6yxYruCAPShOWRAB1GBlUJnTmf"
            + "2Of9rZ6Tl8Xq56MQp/Kik38HBLTuu7+II5xup2KxS2ceuDsfZJNameza/Qxqt/7kEnYyZbhBI9EXCZwkLVydEnneoc5prKS8"
            + "OS9XOIRhLSroBPjVnQv/flYM7IcKHqvfk4ET7s8yAlq/sBe3urV/8AF74cs5fmBtpHVuKZJFpk90AIZ4c779PuDRDGwLSQmD"
            + "bIWKHcsWzoF8ScksY2He4j+YsnPwmux7fPHJ4X+lGYtL6DikNH30KP4NTRFXDJXxr9c0gPTrm1Dmal3qzgyFTsVbk0TEJJiA"
            + "/PdynDEL7olns6JpT7N5WhQCcO1QE3UAavPGBRoAMzT1rJ4E28IAsBvE85edf764I42Z58t0N0xX7NJpSUZ1dK9RQKQRe7Mv"
            + "Udri7zNzEhglOQMJykncjvGU14AXnodGwQR40eU9JYjscjooQWgUbhDkyVd1kP4iGmOO9LiNGjb9tstywpdSn5FyG3VXkDv9"
            + "WpOM2/yjA98="
    )

    /// REG_KEY_1_PS4 (512 bytes)
    static let regKey1Ps4: [UInt8] = decode(
        "yEjCtAjriPdfSgktWR8JzRwY9HooSpZts1lxU3V+glBX5Fmz9ElpQOsXyZ8Xl3GuyWB/+C4IlOhD6tpr5RlZMx+JrkdXexxm"
            + "/v+Vv1Vr1ZMn6qYkZzmf0wyqJkLnZk3YGHX+RANG7j74PLeFlwMHBpL/WRcnCyH3BX9pkA44kcZnI0i6CI5X3ZHQQEccW7/I"
            + "Bj+WoNwA5Zr1O5CAZrsPkzAHK1ZFoJqxsHIM5N1w3Xxav9ToDco35Q79Eu55ml6nHjGvH0ZSyvNCAD3yiXwcd2C3SoB2R0s/"
            + "tpEvnMLxrUQpyzKMCo0FdUah+NoapyDeMln+cLWH85L9tN/0puN9mDvhuhjbYdHCpu4IJfqGinv+vAK9Il8lMFFdKDZaKY5S"
            + "60kUKH8KxGklhWvsMzNXq1ATz+dzeCMGTR+7OBGxbmxvzUsOQoWAu6g5aMlbu0ZYhohXiF7qfDff/QI5RYku8uTwCMC265xu"
            + "eoGjJkb+4XA8PhF6Ms5FAn0yzQgHBqOo9zT+7gawFNZrLS4Br3cR7B8xOBec0ODFTaTWrbnm4ePinkSRml4myszaTdd4anWm"
            + "Ga3MYse2DRSxvuvLEM+p7uJCCDWKXLzxSf5keANJDIXw5Hcm0l71wTs9LczPKqztiFJ0bb+yufdYURxQ9j3yxEcKITBHgS3k"
            + "dQ2PLSKwYyc="
    )

    /// REG_KEY_0_PS5 (512 bytes)
    static let regKey0Ps5: [UInt8] = decode(
        "JNjCaUxneHHuMb0rg7IdYcmnju2a02prXMg1eack4hcGYC7f9NsnEFXZ6hZOkAy/QG9UpTFwLV0eJ983QLqdXf/hBXCA1LfC"
            + "ln8vQutaCN7BtVIV9rXy2Wmlx8R/RmSk/UaYp+Eqjm+vZUIoucJvPuPkTuRbnWAQuFqwfQQMTCR4vbi624/joHVtKMIzWzKD"
            + "3VGwpY0JZuRcuHAL5oIUttKwwuBV84StnTr4d/Wdmql98UUbm1Ul2MH/A6VICxsZDL3gzUjzLJkZ1ri71jVDb3Hj7z6XuOlA"
            + "qEfg4AEWnafllEsd0oCif/KYEDgNuFbDektMhewvI4mv1bqarbBhnFG0bQJJJqQ0hCA1MCMKRxQyGpYO6A+WltS6aDpnFXTg"
            + "1mBMaFBzFC8RWazIMtHbTIqUdTNh0dT9qmphaNiuMU+4B3snD/kLsMJks3Lqi4dACbSCtK12+TYFYInIIOul8VELJ6fwdoSW"
            + "67EuwoUovEg01AGNWyVU4MRPoPqZjW16ZLGpXaT59SLrmvSoenhLf+KLBFBDfSYtGZg4ak8tMBUuT825zp6NEsn+M4uEzltA"
            + "439ybWyKap5U8eNkXW5/rBrn9/oAIu0rI/pYxetEkl3MqoKfI/umyWUq4HkSZSw0xSMWycwFMPOWC5BnGqdpTD5DJJ1OaL2L"
            + "dW6dB28aaro="
    )

    /// REG_KEY_1_PS5 (512 bytes)
    static let regKey1Ps5: [UInt8] = decode(
        "eU14MP4QUkyokFuafl/T4RPg8Q+j57tFf9yO1fEEXHhR7/hlWQM5hDeuWd8jtmA05kvi9UwTxtr5/bNlhNZF7CwA8u3cy5Nu"
            + "YUbl1gGU7niFDmhetVvN02NB/IFDHG98uui9hjHVcH+1SpA+hOFx4AKZ9HHnAu02r95WwpDgrsL5r1PG2GIWMif7bptIxur/"
            + "b3gCIpgsH7+wjqk5vN8X3tcO4XoBDsOH/Krkaw9bCvEYGYrlLDabQDCZJJRI10eyr2uMQJ5NbTQHwSYvuxT3vDZSvYT+Spr0"
            + "its0iarxDZQLkvQc5Gx5LW7AGQrVVZQUBRPCYiOz1CbERFZ6zRzq1HS5NkCfCPtJYgWSmK0dn4p2i9QPIUB2thaRRZNmzBLq"
            + "TfQJ4qwz0G9DUQc+15UsHh8MJLMOOu+V9et33SDyNZjyrqlm5hPvXTotZu3iHukySkC/N8ZwKdmMoWFKKT3HVZyUnskRRRAo"
            + "pyfR09CEecepsPavRYw81N879w2iTxOXeCfwSMClq4MBBdAS1x4SOk6Yd666sU61O1nKbaURgJGcB2lZWlNwfJWXEW1mjaO9"
            + "uy2wv5sQy8cPW35n4rBLuhASubyX/UjkisEPoTCdViAkGn1boLS+nThPtFaoTRN8ROiEl+t4LFKF5KL289lxnu64EUf7qRvH"
            + "QMbhGW1QoSo="
    )

    /// SESSION_KEY_0_PS4 (3584 bytes)
    static let sessionKey0Ps4: [UInt8] = decode(
        "30CCpi7Yayv1bF/1+yFptAAnXof6GqeVFqG3t8ryPXoEl+9J61G86SpHhLr7CHhKp4IXrUsmNJey3kF9xgjE6edzoSKi8ypv"
            + "jMBF9oS011QH1XYz04th5+rWmDL1654bveIBMUUBDVEfd68MNLcjQA3ArH4EtfB13l66+qYlVt5Tg5ROpNlO9HOr1pa2/AlG"
            + "4hqdT/GJkKA09FVgKfk52yCq34v/bMCplq1xZ662Gm7UknrHrDHIISQ7s2odTcCCX1Of+etKQUcnWrw7yFAg6xEC+MV+pNOF"
            + "UpBhToj/gc91WCH+WI/QdfYgqlQ6RVTz5ETamH8JnqZyY7yfRnd+JPjaxJQEqSOn6mfjhUGkS47Bkt6WyAm31EFgifDbCVYB"
            + "wWwzsTe9eW+rHGHpGPyzbLz+6rGezrqD2uWB1we3ivCJOdwwaw2nK8lR3E+ZmDzPYhxW8YaI284Qvz3e5vUCUfel4wrb666w"
            + "doliS6e91v6NASgm83Zlug9Ed2V5RwZDrqjRXiAOcioV2UKW59tArk4rHG1xoo6m4U3ohKOlWUEMnuk+WsgCP7vz4Qr3Pdeq"
            + "5WTGTsPJuzIwqRjsuK5hyRpi60eSDKfgbDP1hOxpMdut3z27TEuhjPBGUmVyr2rIzrMn0zJ4sTnW0V4JBv/cj8oWm16iGGTu"
            + "jAub10H4NZjTXHjiu6X3aAKK0hSFUIuYKgkVwJ6cRx+SwqUqO6p73rjn7qfgSrSBKH8VOOh4/8HtmNhPIz93KaylvNCPK4m5"
            + "mb7B8T5OvTDXbBwJTnwTKPXD/8HPiipB0HMkIzETd6QzwH57wIG19SWARcWUZaSKlMG29GlhEdVD6ks4SlYU3Tummd/lhyr5"
            + "Er9Fsdl0Z4srV8PQsZpKzE9jeVpPHab/Ze6+2RbqqWYHl3FD3WTjAAO8uhvzpqbu7/in8hX5z4xiKh6bvvtat+3V0nEqyetl"
            + "aHc0pLtEqwHleRk3sgcBxsqzB7hVrAOu9j8pEqG6HZQ6o7VsbvQxPzin4DQx8ip65s8/xOm5DwWf7Jrcs1nEYaoQts5z4+OM"
            + "+F0OlT4aT753h86KF/UgpwHw1+Y0YwR2vnSzRH3fETK5EzIVGu3PH4WR26PE8g8sj3cKxAl9GRJ8RvedOpSGSyJnb5BXmXAo"
            + "PZxT0tMLwSm3OYy3Ysi7ZE3P4F9k/Eey7wpojZrNn0l3a1BHfPyk1CxNU8EmJpI4DboccYEXSlkPgP2taVxYp//vGsrW+34J"
            + "3DIXNDGc+nj5iBpQawkk/nXNIr3wEhCdxXu+n6TIenyxp0YtSKEI2HU8QFNZWgT2y9YvUZ5KqO8CPGGoRVqZmnMJwHFvTbcs"
            + "aWwehUjqM1uxKAnjJEd6Eth3oP08zSNTYfCeSUQZnOEKtsWTNU0G3rWsFeKNR2qKKViP/CsyxA5OdbJxRJG2+1BgxFBN2RzX"
            + "KLUuCIL9vXxIYgABMKVHKhBL/j611+IeWtDja6Cc4xIFuRx7PxiIEcNN6IN48Yxqs4d/Z99HxC/qnHmYNS17Lcc+MRNu8/2o"
            + "FiUDP7EUd/+h8umYMuQvPrBuKYQP3YW72grGGXiaa92LQDkfGc6tecnaWb9uvLDIbmHrLrqmUAaMdKsjT52eIGeaDOpgFIVC"
            + "xH3AHGKlfmUd7qH97YIZHpCHq9uAt7KroLzbmZsujsSW/jGCnunJo9DjUg9zJNe2Qcz8roa1eeUlyHZgSDykdGp7fqhb+Ft5"
            + "DxmVfX9WMcw00LgMKT+DVAJ143m2ZPlmf5Dhp3v6F2gH0e81UvNW3jU1FBvNlxrl9LWu/FMM7DbwtDDqm95gMXJ+mUF4kIFz"
            + "CoHiqnBoZ3pSSk3Un5AN2TofjYD6aGJUrrcPOvrtyc4gjYhIeYKK9sVNbu04gXVlrPZy7vAubT8uKlTy8Vq5gc5Wv+2r1TLx"
            + "lYaB+f04HcefVeEs0ShmJoH1EnICNYdlAepP95W6sQmRnIm0SB17tDd2bM6DDiy41eBDNjwtsQ8pTh02WJrN9KetrtuPWdB4"
            + "tMv95hupJCa3osC9CFPSTrIZkLGwp1eq6xFx3TuuBPREpSfrsy7dcH4NKy/ETO7/TZTeb0ihe6Ki7zqjDJlObtRku9KgODno"
            + "FqNLd7ek9sAS7P6XwKT8kIwH+wrJT+j3bkX2q4uxWFZb2hLATOF0HLkU3+QXU7MM4uG8/Oac7e2CICpN39h4bvUWV0hYmrZX"
            + "IPB0zM/dXPTWfsRTE6TxaMWk4ZFYz1yfNr8gIRs0XL0sZMVvf7mRZc8lRJOZH7mC68U7T9KtXq9p/C9U5NA020fvixZUK2cn"
            + "PFCf8Gzm4gjQCjZ2wWViAU1wuELkiO5jC3RkKxXxkGyjP/SUyj9IZFoJNlx8T3XwTuM9822bT5kp8eL/kjhd9vPSxV0diXgJ"
            + "u2o6CpwBTNn9VUih96GcVcExr6UDu7qMdgrw1gNXcfX+rX82I1e6myCSFJ7PdlnN4kcStB61UsN/2qA1wlVWl9BXoMzNJ8wI"
            + "HJwG/b5H33gIF7Z/MR4K3FTMBve/7nRIITls8B8pGXYZf8I4lIrkLX//90VXIZiqZTW6PFb/Yoi56Onb0fhZD1ATi8LCvbpE"
            + "RDbhsBMyOmhNYqhQh0S7MfvjJXOg8Sz1NBkJZqlGIceikX3p9J2pgij0HyioqQHxl3CdYXLVi4TP8XzCfaejJU9oP16OthYY"
            + "eM9jU1cIEVVlG1Vejc5oLXcWHoem0BFEN4+ii7DbSwEv1x4Wk7UZrbfeEw2szXdqFWHr4NG/z2kQKHJY/sfOvJL9X5zWbVa9"
            + "OTXgpnMZRWryNooKWOEjByikiXpRu7rWQni7X0ILwI/JPMN+QSKUPALTLOz4jxRifHhHc+jVQC0mgnIW192ejY77r4Nz2E2F"
            + "KFNywbAIWsZuvvkh3Yww9V6+7MzSihrD9IOYhjtObT6evoSALye7aj5RGLB6goICU20tKqtKLjukiJCZdBAnp+lcUlv1sADH"
            + "UpEEx/8Bt1ZAn1ZU3pZlYXYGttsWyBwL//Bz0IkihsasxbGYIdBsMJJDtKmAyN1v8EtXgG1T+9SVOd5u9SiekpRCmUJNAgp7"
            + "m4/GMrDZXYF00nbbZCHfwu5fd4gTYDLYl/Qcd+BJzh2iu2bKJ/3BljpQTx+7ViSFdnf9hHu0PIcBCYlMD45EwEk5SYuTCaaN"
            + "k/FaPx9kL9Livpk4OPHsFUbjipXmPPijOLjAIF/LNuSQeQyOtuVIIy3LPIgxNeeO+vWBNjWWmDmwLaPXhDqSMAebcGHa1oCU"
            + "e5MBEOIDI4PC7y9OMQGHDAsMHyCqdVK1vKJV1gY/8WoepABD2w+a1MRFLyCUV7xu62PakLJWm2yBsxXTHeHkdao7v0VG1w0x"
            + "sfWL+1s+SEvqCQyC03pFHMJN2k0I0V18tVAkvztat8p2xO5k98d3LQaNm+58a/Vrj2JNN2YxX94rsuRw2utJ5Bsf30XuWmlo"
            + "WeVxFMxOc6QgOFzHpyjVoL/9ag+SbwJkSRnkGCOi2pt1e8jbj3hoTGdHgvYQRCM2dAJYrXXUrVmeLplnwluJkQE3Lv5QxG3n"
            + "izRTItDDHxbJFC8Ldt8puTLUzV4E2/VHP5kmy2usriu8dfKNZP/SK/uMgXntjYaJx/3o3hrhljC6443IQ9WXUuUZC9S6Qeqa"
            + "rcyUJG6cj9Fpa0pQkrpzQbHRghC7zzxL30nc39O7pqxjvIhqTzv61N3UPDrlaNeGvc3TbagiynHW0KenddJw1LQneCvNFhCB"
            + "sVn+5Bti0c9jfHJ4wpaviHYoCkfrqNnR7+oBIBVjibTnmaA7L9+ZC8PvpvPgkMmCTD5R6SyGfTF+j116JP9lqba8GMgoTI3a"
            + "x5hqVK0iGco9TYjMTlwq79BgPONJ0vZZOCXtMVIYtDExQ4+FfVmo0iZMoPv422oSrUBzsV1h9Ulle0QwSXrX6c40nGRuMa5I"
            + "rUxpxNn4KrB+s7rs6itJCSFTY7fG1oCcdyfp9scGLI7BuDEVqYcT/f0yGN1cuvNwlAmdtrwske9CtxMlkHcQ3YCp2avvz751"
            + "k+K85ybfd4jgkMAtIMmM+oKRV/ux7N8rL5tqI6A+KqM5jOoJBgN7qOd3MiEaKc0iYJvA/sLznINWj/Airf3jqePFv9HzvcZD"
            + "w4TyRpFbN0O5z+RHelr90sC2fpnqFRsxPBRrvyZP+jg573VM2kxPAO8PxjtbTPEbNZK5dJ4PFiorPKCA8OVWqtsOT/xfstEL"
            + "4gQe6G9PgdvHGgywAO2Kex1E3jD6tog7c4GzVzE4DhN3nlpNoZNzMA1EVpeIv8Q26eziWBE5M3Fr1LdKmizArIjrCIxDSKK6"
            + "+piVki2i7nKzftkRGqNBxGUZHduS9D70qkmtd8YD3Rl6jWIJGdf304Txy0VU0XQe+Oak/aow+PnhK89lIvlzz13j3pOUhI/h"
            + "ZplqcXau2xYrc6tOYQig3D/U46yJejHBuSCSEFgbh/3jfELIJgZQzrsAC58J3Kwx4M2m7iPvZIdlX/tfbClK+dOvTqo5MIIF"
            + "xhweg4/k9xzKOwMBgORqhHHU6aa6colp+lZtJuMd+pGPTMxQdHUv45cWB3hA3lgiykHeuZJWVYmFIERa0PyITkmBMs9Etu5Y"
            + "DiL4jwUqeDA0EbCPIRC34oCi4Gm8KeNICKbcvGjX14QjP7AKaaGHEykNcT2trfBeUwQDnkuyJMKCjO9McM1Ysxmk6A7A/Vcr"
            + "Ze6lQwLyvudmybX9cMCTm+hgdNTMpaaiZjXcdPMCFnSakQo9pIuY0f0pNOpSiRZi3e21i+3kA9k="
    )

    /// SESSION_KEY_1_PS4 (3584 bytes)
    static let sessionKey1Ps4: [UInt8] = decode(
        "dmWd5PdsRR9zQkfDkjL0OG8oz/pBhL4bWiOZ+s108DtDydEwZnderDmOimxc/t2A8wMEMISdEu5K4w9eXpfQ+RtXBXQDWl1B"
            + "2m79Sx7ES3bk0znrPCyuJ+KY5AijvrAxaRSjbN/8H1YN/lUSl16tPZvuta2jVoXDvZvvrFWYH6+4C67t84c0yVtp8O1PA0Cl"
            + "cSSiI5NS6YfEeU/pILwEWHCWsdc3xClNPVLTz3wI6YLGmfXbYBGbnSWGCLN3J6gs+SgvK3BsS7seST7WadjoCfScCTLf3eEL"
            + "QQ4mPlPMetEVFvvDCdOtpOqjSr7yiJo0ewlBRPFePE8On1qVV3r+vsgkH5iFHiV0kN1a0XwCvmPlx6ILJt8ghGHj/yxpMpFi"
            + "+BF88h7lHsGyKoSOOnj29nZ2TjRPJPCMNK+VejUmXijjLGb5fzX8rf5uS+FcSOwaur2sc3rovK26XqbwuFpRKpfkNIo7ZGGX"
            + "V1kph3aAeAWRwKVee1qley+NB336dTLoSAxov3CzeYjAvbxJmpoHuKPCtB3KJJDoL+ifKLpAF1BWz07Igst38XSN7wtMHz1N"
            + "0k5mLxPnirbq0dc281FlB8GIfa70uIm1zt0nvm9sgY9WAg1J5D9gk1WjaHVdxVoJkNyPqp9H9qmt21viZM7BJuvroAMjYRSe"
            + "ckjCED1zw8kiAWgsPJilhQ2k7Mb8ff8srmDEsHG5vNspxngL9oI47TW3ki/rqefDGqKuRFFxbowhn5xdmHKjLnRJcK+FexRm"
            + "VpmJB8SpwsKzOab1Wz8wzC0DIrQqJxpGvOX2GTTBBm8ohOHjsCEhhDQzjQEmRF+jVhlGwXgpOAuf4fEr/AGRcRylnLbhXvom"
            + "Vj+ostHk82kINqzWZ7bmuMemehBJ57pvv+glr8Lf86F29CuMbwHOljDSLfhsre0e5XrfN+b/7Z1fqfvxvMdHWm93gxgOuhgr"
            + "OLQ2MjbcmOwWoWhCle6tQ0w9Mc/bV64PeFLYpkdLupTC0pdWK7C9QzAFSzB7i+TuYcTNywixFi6j5CAO1QIXgbpD9wJ6DncV"
            + "RQOqhIhWse46H+Yo/Z8FgY2/U6FbvZx5Uyhzug1y5xTtXbeVCaC/73WhIKQtFqZYYZM6YkDKTu/kMRjROTV8eONsdoo33cOO"
            + "YOINZ/znN4hItuRLh+YEjAbYx06al52dofoRJ4w05wJVD27GzWvE8KEFaz/EyUeVhR+AaiPnJJ/D0J0X6i/6+uSmiJpXDFv+"
            + "tGc+8ApYoMjHFtYLQZ6p3r8XSQiCxE5WU7BOIx2oB96Y+OnsRTtQ9raj3PqhhtP62rYdJ+09F8nM9i996js9WLfwSq75L6CA"
            + "6d4uMDzWRspQJfeiZuylbgZuAD4IbOY7+8in0B7IJSQRCzkPcNn4/1RUnQKrTIyQlOUO1WJ4q6WcERxwB5sq5Pvt+82SDbwh"
            + "JTMLv/MYk3Pt84g7Q5fOGSX1u3EmmCzW/zJPdcySTuO+uL8zieUJTEGMsFF0MuqWznAcXCY0Zjo66JJO0mFwEjwznQlXI0iB"
            + "KX/JTQboxW5QfI/68LTmnH1eCTazJMT44xmoZT8qhJh5GFgmKV68PH6AqgRDG70271zGePum/SZqpLYukrd6AqfIsEeobmpT"
            + "FYF9HLBVvqkRHtDYmTeuNfrkC0xSDBI6XwlOIcYNVuQj0l6GfwSwHOufUBfMjvmPAJHup6SRWbcRnodA4kEID+xAvIwwFMyX"
            + "yfBQe1wY4hsCf9rA5iNLSLvoAenUuFL6NpndA40h0xYXLCUgcJLVV8v/cBYzGPMxGrAHJ4LFE4Y9tSL7fSpNRaovRmcen8SL"
            + "OriMVjyk/ueTsu3IGTzAXTiwolTocdFpx7jcMww7j/Q3Iz0ee1DFTDpqjagrPYxjTlJ56n+iDMDcumAEhqXWK6sqF76VES0U"
            + "TsFCo46vV02E2TyRuUUJavWzJEotaUZRZZo3EX3enHwRr4H63x5d/7JkM3Ujf5nCprgw39K2WjVrxSiwYBqFWS4ri4+aTNKb"
            + "kB6VWvOsNHiM62cJa5VzXlQfBdbk9DtNkxOKojZiuXbcd/cQ9nO3SZBTmr6WnUzU9QkViOjHvQQe+HCIffks9IBcb1Vz8qCQ"
            + "tLS5gEk6xdqEjCaEkMErpqxILTdhJ9IYuFEoCxO7NVjm8CQYKEJt3broZPL/RydZFlXMW1Sj4vvvFGiNvy6avPq4jl43ihtn"
            + "CegL7URxFgW8Wyr4it3ZdFNzsNm5/dZnUn4sUDbQO/cf2EoGEfMhH26PJES4oboKu2wYAo7nW+2qObu1mQDZYiZfJj6OSRHU"
            + "LnBeeQhj+41wj08dTzNyzbG9IEx0f95U4x6xDbHrXGPWya+CpsUZ55Yvrxl5SuR40LP8/9ePNZNBLVny2Mx2uDr33xyohdX4"
            + "VGN1NuowWhN0+W1VJwQLoKBtnjqTv06SKIXkz8UGpxda7MJgaqsbUMkLhJqCRR4pzIVaqNSQ+6cviaeA0Gm2yuAATujqEnSF"
            + "yDXqHSN1l8sdlG8qqXoyxZLwCii9d7y+rqeoNJYmr4MqjunarbJSlHRpcBnEyDbzDzIPbyt1rA6dkR8GuuOcf94WOj/9fYhh"
            + "kMqYwc+lUB+zjPmM6Z+j09fOf9/SjoScJMOFscaUj7tVg46jx/WOfuYwEwZhnmMkJwMB7+xtsVaG2fMu/OK7paeqnAbzNgSu"
            + "vQ9vucdCef2sjxzMAZ9FOlKiIDH2XepO5xOdeeiBYs2vLmu1G3X+YffPTZDf6FYjluSrXaXYLp4MMCejLBDaea+5FmqJM+dG"
            + "70PlXrY4qge2XdhXS5S90HOc+akxinHl8Ob7TsTHS/7iHrx3ujssonEu8dczoq4tiWrLY+2NgxCWtEPvwuZJEy8KCa7KqAH/"
            + "yWWHjSCYX/sl4Ho6y/hIfhjMTGbTdhCTon07DUnKqRgqUOKz3Hc8I4T+54Y5f8cYyq55/EQn+bzO29rp1YOQ+4x5S8kba1cK"
            + "iPyAfRcQMn31h/cY1npgXCtKGQrqP9FbXpM4n8n8bGeR1gw7HqYtGnF0V2dGopOvnYUOCx05hOF8ihHte/6Yryt65sZw984T"
            + "5lqWfl12MPwi3E6y1VlmVHAlgx8W8Apy1bFphhO4bA/gWt1eJpqevJTf0AhPyYfz1W2tZb1S0hBxykvlcs2up5xRUgTly4D6"
            + "IxtKDYOKppHvEAgFKjkUL9sflo3hWAjQZW2Dj3Hgh5CWzqSgMPdW1IhhCGHa0TaKkj+x1NBvV5u04pYSrZNL1lk3CE96yH83"
            + "jhFfB9JevlTLqMYu/CN+q0AkGUxRGVLMwnBjxjQclxSx/tPmmPLXd1ppxvYPuWKuSrAzOkMWK2a/xoxBjQ+UeXeBASPZXoF0"
            + "HYcRdsYPQJFy6X1RuHKpbyMdMjPe2PecUqRtTz+e5Poljyd4jd45ov3ROQHrzqxg5J9pi/jRhXB0rR4wiZ+EWP/VhEGmaBbI"
            + "B5t6MykFXA4IlE0YgLoQgk6SYKj/Gg5GVx5lZyWNKLHbZsrAvKmQinRSl2gyNGCwMGDViRUJH5XFQeICeoF9Sd2MJgX+7agS"
            + "pD2CZT2H7ZWGgD/GzSdYVsojyqTYBhG0JMiKxTZC49T3r3Ssie5HLove0IXULrSumZaI4mCZ+2Jfi6ck4sNyTG8dzcE6MgaY"
            + "tZKCmLF9yqHhTeHlrzoIDWgzuMDD/bmQR1jKso0tdX2708MPfadaWiVvEthp1MEgGWVNNnx/xEcAyyxkEwYKNx0dfYmcIdCq"
            + "qQHusnDHwxFg2XPJ6m2KGw9pHbOVglL0qU4lhXXeEjwRcQaI8DmTKTqUfHNC6ll8HZMaFBBMXpIannHxQrlyE32ZSiiLkkgd"
            + "eBkE+MTzsRwvVrb2hwC9jIxW4Tj4bRnnfjBSxkdyyaEw74z2I7/70LtRqfYdp9LHqqbIpqZhj4wi7m61IYlyDr4AzwiACQZN"
            + "1NTqtqCOcchzFttVD+2/t0BBmkf8rVv0hjyY0apRFcMQVY5d953UETXnBRF9DytE/hJ/OaYZkYvQrCwYY2ozwnXSzfciRsrR"
            + "+cAVCMcQZ9FCEyciw+OUZgC/L337xW+5AyTO+/RrreBH2l/qYf1qdpgVdnLvlXeTOyPeCTgce9XRXMXENAzYwgW35bXJe8Eo"
            + "6sgHmOKrcyT7784Kp7mN6zEJgvKcTfEaSnk1p3t78KnnuflSY3Mp5NQTGSrynU7MKrPflcW2kTT0EC7nDfg6bd0wV+wFcO+A"
            + "jIrhLp7U0bTcFIf1l0ss2ZNxOhUloIqyk7Vi94EJnI3lCbLaB/Iz9lzScbGv6mIF81/ZsY7RXfmJhXjVVFZs1CBF5wPMJX7e"
            + "QD2yRpBZwvzcFdSAW9jsLknX2EUOfboJMmDbZNZE1+q0sbb8G95KSKFsW1ofNVUY0q6IRl8tJbDZT0C7I0CfhRlO1PzNxFmY"
            + "J+J+qzZSUTD0tPOhjYcB5S1CS4dwld6dgDZOihRAHCeJ4ULud4dPTbA4PwVn45yI2Gh18/mSjni+Q7koqS7eyb1ImU19tro7"
            + "MSCfDMSQrkozF1gTtf3s74chDM69vYVhB7h/k6q9xq5jLBJqquKd+FWsw6NA+K37IYlckCFAV/sIXSiDzEZ2RC7kW+c3ecfI"
            + "CgvCthdIjCtn1vkz4L1r6nl9bVsjfl5dU88B6oZfiksfMs3bMOMnPxBLujz5QnhSAYft9BWkjaAdx4n1T5koBKeH+Jt3GAq4"
            + "WfPNdPHVE2HKApXmUDCWgzX40urX1l+/q5uRycSTV7VVtoOwgxd4ybalVZstCB8JNxwKOtwy6yA="
    )

    /// SESSION_KEY_0_PS5 (3584 bytes)
    static let sessionKey0Ps5: [UInt8] = decode(
        "f66DIEc5tlsjm1ylN8TfWSaBClOhrqOj+b6qn8rgnkWNQ39TPsAXkNIDLZKoGz4Xmp3JRTmebF+2skJXahqgNYndasapLQai"
            + "03DVp5EyQlpEDzWGGMB1n44HtoBGwbzjT8Dcoa/7GytNthSPr+tJ3Sqz/bIyhjznGpYUnbHZkHKzsz1vPcwmvFHakW7Gqfmf"
            + "hgcTcNziIddMs8OYApSaY200cy2hI4OoWDQ/MBubAfv65AKjUk36yBa4+sVn4Yko4eX016KfzNQ5kUHponpEtLZL6dcsCxPF"
            + "2aRQDBWUyGWIrOQUdyMEnjDsPyfnwrF2FbtFRG8bzSuuB3djGt4QrebejFTlmN7MO4vhUrJ4pKaoQwrbataX5BpRioGcfbk1"
            + "Z3r6v1nObDDYAJVJc3XG/Lf0kxYYyRtucYQwheMAGUPLBGFYg5GL+Ao9TEdxPDTwoe5d6sC5aO6iYbm0aRIJkHRLxLyvMmuc"
            + "aXIVO7JdLFmVK3LDrkVM2voMZpz4I/N0nfkOXBgiAg+WDOmbuQX1+Ti3zTYDsIlIPjS15o/wpyCtQg9VvBaMgau3bYuIiN4U"
            + "WXv0KIpYJrztAyd6WTXdD/8juxiTVv9I2NNxocNhMIPUBs9B3oF6EBbO55/clyTDYgRCu7etE04rDPE2U7WkFOzfiqGe02LR"
            + "6MGjmod2BgqEdnuI3OtKaKQPg2L99QFQi7xs0OlgLOXviM7Gg096MqPADgWDJkk7iOW5JsWPu+NUBWuNQlYEAdgL54MKZrKU"
            + "8YySssOkdxyxXSRDcC4dQ6UDJ5T2qga6oFjwxcjpgAmYycGV0hMzyPsDWjek3ETXfktBy7Cs2niAgGyy3+ZcTB6C1nZWIe/Q"
            + "bA7harsH/L2iNIZfsJi5pMmF1LCxRfw8UhcoXOUQx3cDulGJc2ooaLQBsvNtj0HyiBkaKobi1rVAvPfYa+niTwOuFH5c/aH2"
            + "2qds6+QBoGSetq0x9rodiIX9YmxLEMM9lxD6L4MjVbB95iDprokQ5Pz9guQrWk7qF8r4BboDnwYCPbScNSerR7FneHlMbrGX"
            + "s7d/VKcCVTVND2Jkm+Z7u2VdUyEAfOOb+GiuvA1f3O1N/tAubJMM7z2YdHsw22yhcyAI+Hn5BOSjqviEUEefBTS2GAXFk7S2"
            + "B1S//2sfS9ZfkGleEtmESPO44pWXwK9NaIgdoqGWCjLnVmvDPO6JMdXxI1zsRTxVj6Y5CKjyASjUl3+RY0nix/h+ywEa3eBX"
            + "+H9xOxfU2Vcg7UlNj1fFqmVwn/EsdA1XBxYmdI56Xk9Eq3fpeeKY5cpkRXy/jHwNunHsv5JGlnVeYeJ8SU/PoZrEO5kLitIS"
            + "MxcgoHYXIz92rLTMB1piIgshJ/aAPTDcjC7385bAvwMQ1r6j5BkhKEnkp+ZOaXmPCVV3XZBf+oM1yKvj2Bh8FIpzaDfC8raJ"
            + "wEu/XLOeUISalb8UlWGfuUCpnLLxPRs0ySa/sw0vhWxIwGZWwxow6liWFcn4GXugB7MByPzgtvQBflh+CAlIM4aa6rRIUehe"
            + "aSBqOHcbiqVD5GcUlhjEfku9kNYDQ87chSNokAlyyY1NieJIbQMvQuAaW5YVFjpWqamxrPOWWG1hE5J58VgLVlsv5UM1gnjO"
            + "PHFskcfJ0r8wtmiHUAaYVFErLlcVAR+FBl/wviIJFCq/NBGeMah8nhcDPQzoIQuLYQMzLsIGwMYMpPF5GALezz1s9108gYE4"
            + "GmOQR6pzJdkYO4jN3gbWvs8uIGoyu/AS/T6hv1hjjQyvH4HCtwPC91SBWwRuPklauvo57M/oEogwg6Yq0gjVrjxjtNLZCQBH"
            + "KqOupk6eq2VAMqRJx8woDOZg+CPUi97ZvxAY9DmffmSe1IwE5uzGCcgspNTiS4QbxASQ3/RMaOgy9sygUUiSbAGesiQLdnZ9"
            + "KrRoJuOuDeUz+BmGGU9aFPsvE4POCiTLQnqmJm1S1purFTYIv3VBFnVGslng0ljxwCXxEUpsOTzO2uyU3MsK71pfaBPHdQ/d"
            + "fYAhazLcg4qkqxzHAyk+7vOLyFqaMGHIHVGoi9eh8G/j7IgRO52/ZNrtPm3G6jbhvFRBLks4pSmrykhTnjEFXVB45Q0th3yD"
            + "8ecYsof3f38p2eAfyKPDPCl+Al0+DKOikGvpGVcKJWoZ71w4q0TtBKpYjrf2QVJSQsjjPzoHyqXbIoMp4ZmhiRYnsk4ZZtjd"
            + "mHCrgxFO6C09nFiP0Ov3mrocFtDNqP/bP7wZrpAbzgIdddPRb9HC8OurseJHwUtzRnu8O+/74GPPqs9MBpHUAL2HIA1OLQl8"
            + "E7S7byFqMKhNkUbAS/tudPZNuzJb8SdLo2od+B6awGwWBEvKttSuealsPC6ytO9z0un0cS8043wb8VINqF+sfEjwszcFTb5p"
            + "J9oEwjOjRbE9P+ESlC7W8fqvG5HjP1lAJdC62qBGFFkdKdPc+74ltR2d1ZMDj7FyRfdribsEvywXeipsoYWsiJCK7n4lOSno"
            + "ao9oJJewTY6cm7XUC2zUFLWhRzAd2IT2tbq28pDO1pxxceDzzIumGIhtHi88a2mJ4TPF+0xTVVUQt881hPYH0q7CxPWc2Ot9"
            + "99y0u/C+3T0/y9KhUp7JXAUD+Zz237PU4lQ0Ymb4pu1t75+mSWGHL1RImd3Vo+LHu2kXOtxvvbaE86KMPxYSUGKgyEfTpppn"
            + "5sX5AMoynyCH1+oVGLvgJE9bArQuyRxmRVQB4+DQwlyMaRyn9xUlfXa0uo2gXx5GjuFA0rcfL3jstYHEp7EHTX+hFYV726qE"
            + "gMZaMsujD1+5ca76Ayq1+GGWgMvfacawBU0acmuw7T5Sb2D1ZE4Yu0UM58IavMz/bT8VV5QcoiU9tUbmwSY54T2kRHTzDpI8"
            + "1qGT4NZ7XdNgYGqkoCACbolU9wCKwTx3/mC2oBIe0f2fPcYWHwkBlxA6oVmk+N7jFf6Vgw+cwsvmkT1JNsn8AkAfOpH5bgin"
            + "s4udbH5xq+ZhorHvMaipAhqiifjs7pf2o8Cnf8q5dVIY840CuFl6IPbzFDNocPwC4XRPbsmcXcfAs+RbaF1WQY2IQJZV/nGQ"
            + "UGE0wWCp8JIHcHJx/FM1nCU1yQHeoG4ePgWVV6O1vsDFnkzQCVD60xtrkM6FSBK+nZXzx13LEggsSeHVk2dSo6yP3I9kqgxY"
            + "UjBO7/j+K77TbHsw1v9ClNy/TmsN71zZhEMQIoUk6ZpLr7aczntZDzxRFsgrGNnOn4KG78iqVvq9D9CPZnbtZkiLpGfRytJi"
            + "E3ze3/78+RoWSvyywd2SRJ7lRGLu676kmpU9s2k/2pok3JBW4EY+kPXqmFeJm/HSZ9dGQ/V9fSzhatJ5d+/RoQ+MGtcZVYby"
            + "x6ibMvleRSNSLbbcZb+YpEH/u4l57Bai+AVpZN+Va338zj2h2L+D4onJGja5/8NvBBr8XGw/eHzz4gtyVROLlxJY9EpSNsZC"
            + "yvXwMZ3zYFYm/4H404J2HbieyFOrVCL47zeOw3vpvyUuVioYqew5KKWcjsWqfaaXj0TPYrOhbybPXD1cR0CPXXBoAWkmXUWg"
            + "YLFJqeNs5ypkAp5DNw9X06XrEeZpVdGFbHjJi0S8hYCTumzj0jmVxknRqUZQ1rJ8ElynfyyzqgFKBljv462M3MZF5hgzyxm6"
            + "j3ZyQdXjqY+TUNx6zU6Uwqq0wPSt7Eb/ZXNUtfy70mEUrqv3UpXNHD8lycnjGXlirAKFisk68cXSvdyP187+olgUxaLZ7y2d"
            + "l/fsVfcuTA8vO97AQX99KrlWq+b0EVK25snmxu8CbkrRbTymDLjWfjE6oM7MDDGryOg3/Q5bw2L428v1AKBAs0jrgq7S00rq"
            + "Em85hbuYtzk/8wsObcqE+PE13Oe9HN0hS9/etcwWhw/ouDSGRfz0YZNKfyw/69HOyGELckk60z8GBUzgI02KIK6H2kxsuLl5"
            + "2hxzXrbyA2Fo/9W/mgS0c8jatYI0DJX72nDLst6oCN/kJP93XC8YDIIf5ikJj/5nlrJHnEM6WOhfyXOkZTzjf9zeDd8cTQ4+"
            + "w9IcwQ5KRPd0zgBpQ5m9t6E2/wrIa93YYi/1N5WNkdigW8mn/mzARXwADUq/PgBQ5s5pJqYdpLBLTgJbAQocyxFudP7M4WLX"
            + "8Vb5O2lGjBxSNyUzNQPqUXophZpYTzifxldUuo6SWcxPiNVKM4KfLH0rmc4iOy3Jb004h0UgxWdB8s7ZO3dBrTWTClMashXJ"
            + "kbnHaFwbKdKZtTiiYF3CLDbv9+364jPbtDUj1BiQTuO07M1CvzUoJIgYPfyXphKWaFvUW/Dp2se94co/hv+OFqooWp29atOn"
            + "e/gyOYeiIQMRE+bnhmiSkwpxpVuVAa4JtWjuDdcvJHpE9ABYIwfTJXwaSEogBh0fxPhboYizUytlidQmC8HED8Uvq/bIxphz"
            + "gZGHfJ9QZlDDzP96nCUUc5RLilGYI1KWIKjpDzg2xFHs6uTq6Y5ERxN16rGQCmbRF9XXL55WhtGYnCSigoSt7lDYwVLxp6KW"
            + "/jRv8vc3U3+lT0pe5WUsscUie76wmWHI81QgnG5FGt9oXIAyrdOkrCjrAsgxwHRbm+AgchKTwpMrd8ssCKpIBwV3J21DG3XF"
            + "2h1rQWtWXPMOixei6BVjvQf6z+ob523B84oLIU5mR6TU7Tv6fGWsTTjaTyrJUrFuH6663owdc0ncewTf2twk1uEKGjCFAOrh"
            + "yKmYhN2mi+a/liufJ85xTUvcIcsvF6ilmKN6sSR5kh29jSKNuBpeDD8A5+abQ8zhnxzeF1n99Pw="
    )

    /// SESSION_KEY_1_PS5 (3584 bytes)
    static let sessionKey1Ps5: [UInt8] = decode(
        "4TQXHfUX2uEb5gxzNdRrQijNRwZOlofVnQnnJKAbrTJtBnXfd2mJ6wMk1jEjwPYNYAy2rUu6nrJm/Y213cn3Z8OTPx7Bh1w0"
            + "riREwDTz2R47YgugAKIeE5um6IuRsUKxK6fOxoVu6SL8bXeym3FdGvS2k3KuRkBdJjCY+Me+tyxuGxMyerKBppbE6BWCxOrD"
            + "KHCvP/Z/E6ZzJynfFzjUsHLtkbWx5tc6NKlnRWcCwsY8IvAi7P992izkZ0drMWP0s13bRzOmHCGjSA9/yYQaVw3VctYgNDZB"
            + "DkMR5UORBWnPeXCQxXrzsT1ZCFnhQa5lLlzLBI1MrFAhkwY2tuCx3EyYSI+VEmRAh2vd93kKwR1n+fX4znWUCmYX7Bfu+vaI"
            + "i+suBvF3HSLTTE+NqGpTx9RytOyXnTFI7WLSQJQjTBA3IDu2nxyZz86d2ufJMojpHTe1p4sZilBQLamJTm59v9J+4aJrPvEz"
            + "DnSIltijAC2br3GsaGMvqUZsc12w1pKjA8STtkh/PBUbseBAVo9jppTJi95mKl8ySo2mUN/fqiDh63EF18rhqHm8g5R0hViJ"
            + "yFmXqvD6WjenShPmNg/mRSmJthEy2w11WOKaGhsIZio9ZuEkguYLxebXnBijTS9ORtYhdq+tqdg30T3+MiTcxL5pLpePCbFV"
            + "mz3iRhyZJ00G/3J67+maxOmTxPC2ZKnq8gnWoyBs0RvXf3QA9WD49JmTpcIrsemDOTNNFgu4pm0wm5e+nwweTv864gYVuled"
            + "YHZNUIhti535cD1mhxEemiSqpej4OGw+bdrl/N6eKuTm7gfOSF7YJyMQyXKdfNldqLqKHiLvRiJveS5vc7/Nz08T3F1RC9Wp"
            + "dsXjwJDpMij8n/GIH6azRQSnHL1m57vBSULbUku72WOPbZ071+NJvHzZ21BnbwdtCCrqAuu+ItEXG/o5HGzaVjfTjvTjIqps"
            + "wXVxTCE2++ACVGpIMUB7ZHx2MeUPwdi0KdmcDIDOo3wvD0wRtT2Fk71g1Fw/QVTmULGx7YUZMIFqlf5KkygSPdx2rFnm41aB"
            + "HSn5ZUjDcFAvLExpAdx1PRT/X69qx8GjOxKlbdeV3T1wZ8svIl2snfIcaidFWSlaT2w0Q0OU0eYd3tp8T9/2oULeiMfMu5mw"
            + "SaWdaq4/sFks+rhmJvXbt+jFs0X60tPsG8+DxZZmkifUiL86fgAisoqA/vl1GtHMr5efbNZ/H27hX3crltYhc/lqjpllGQ+R"
            + "51FXLFl73LKEBhJt+WFMp08silj7w2yQm8MZcjREmy9Tw29O9/9/IgTUXNcYBynIPiu+qboXO8uosGOQCSJNv1QxT0GLqouO"
            + "GQdgYtxLmWSV6vbM/Jflf9TZuZtaKAWPMH1fEVViZJicKmtuZKw/H7xFmA7tUZIZhBG4j+e3epvAQVCFycIO6YS1zHKm7NTd"
            + "by/QtqYDqtOZHLdfetqf5/+ljndMFIXQeDwPrxxcCXlstGShhtCy+uv82vNCOkOw0iT+BNExR3feD7RVKIMUXtVNmc7xuUhu"
            + "+BfVCqCjes6aGimD/EJYc0gsGN1Gtg9evqM+LqDW7+j4iNgERFMJMwf8cAXHTlbqJ74VbAqnBFo1Nhye64ju3WNMNKlwk8jq"
            + "g3lvDiXFCzJVvAp1kIKiGC8SJjGS60c4YGLpzrBCiOaEPBM3TSt0Ae8Htp6ZKoRLb0Gaiw4Bu1H5c3t6UVBoikG+tpH2Xelm"
            + "7/3zjuIky8pbxXWHPxVu08Bv4mGrl30iZ+87hLPnbJl3L+2o0fZgOIUa75F9QKk6bkXgmYOAdALjBOZ6ZMkIiqSeZAHOobg7"
            + "9iINjHv4/NjwktyV3agF3lkvwheN+m97LQdNUz6AbF1i5OGfk4ouWd6tROxHEmj9b4cU1Qzhk+zAoZNNLf8nABjis0DfHVYF"
            + "tkI8dt7SDaavi3GTfZI/VfCZNCaipcgV6ZFv18HH5sWhugiOeKw70tPERpmXfXEnyS8VfGXCK0DIbAWLbx78H3jYSJovtDi3"
            + "/JLbl00DTPm6aT9Buzm6PnSsjleNRWudiqEWsOp9EuUIDcK6T1LbuLZMB7LcvMd3AbDa/RUrXs5dLGtVu1tE0fg2m4EZOkcY"
            + "kyNAqhR/47XWHnAmhbNRJxxFyrdHqZjzs6k3M78QgpXOqaRXnOze+ysr2Mdt5Ewpfm77JuZCF9/QH8K3cdhEa/YAeFGgVyh1"
            + "AA5PrD3mOHWgGs9CIKAig4Cz9l8VhbWN167yuLHBt9bon2poMX2+83WqJMNBp/yv09FxsGDMNb4JSX/2lwvxa+Ut7INTiiC5"
            + "lrthHkcyAirlHKif7L4rRqYUm4TtkpDuCGVLBpkjhLqXwYxC3i6V5J3gb40ViamLdCr5S8d21PVTrpVET2GGEp/y4jdBCYZS"
            + "P6ykmE5CbIHAgoLCTMqAd9EIO5Bjl4yAq0i6G1l3N3iwldJbq9j28c9AGm5AYZU5KhdYUdrrTAjxlO1ESLuq3Xh2MDGG/ZHX"
            + "+NnUGlqSPxYRSPg5eWOiAJQTcOjBfpP3OVjuO/qB5sNkMWv9+AF1FKy1GC/v1UJNoaVGkls3PT+Z0iPYdRCBdpHbPfMZv/z8"
            + "sWw7amfwuQpuwsYSiFR4Zmi254E5bxhFNEyZqk0j+F/L5+y+vvM3k5Z9T1eV9epqytFOivBGNMV5eM55R563klEtj12rml5K"
            + "LTksESQiD6xlv9ba74IA+0BTVfflpWqExjYacqYq4LKj/h8ynP+KPMzR8IyZvtGCtnSIgplu29DiAjvuRCNwFBo3awmyDXlL"
            + "9qNjnLMpKcbJKArO8Jb5uzt6rX4SF7bGXxYjp7+qSGBgg93zKtySEWIsjdi2d24aKqU02q11ZIhzP1H+yp/pZUoetoEFuGEB"
            + "HjZBbtZw48mk5x5sVcbov/7PHiOZyvCnVz6P9W8O6bzvKBPo9y9ewr6seTetu+IB9GN/75q8m6dacPoCxqRKu6vtQWxaOL/b"
            + "sW3X4jr+Iz9ssBjOyO2CXU0YQ4lXBv3ClA+V2kOnvMdhOXGPnUwc5YAtN9TRTpqmaUTfoz17jFZxDfB8vMzeLAA85kR1vnQj"
            + "l9veGbhDOyBAOqDenF4NdIif1jc9D86s7bCE9uUjkAR5J0IBnkACcuHugJVpb0QMXIIjK0N/Vez4+yPtSZIdz+/PAgTYaX8/"
            + "+IvubzBNS07bivzTtQCAUpmcq0aUNMoOMK4O+/oYY4omhrmHBdxiZGI6U5Yjxmv2sHzKDDCQhZW4ehulPrYIgNVktmWNavNa"
            + "cEoReYrgrClOhBvfy/jEEjtqrUIHGnZe2lojRB0tyewHgNtr+bN9YLWp5KxXGmKLLgdAXXKmVUP59KX36y349uGXbYw87534"
            + "/N/ivfSWaTG+aeNzEqtijYy98SXYnBNonzG1I7YWH+pdbmTbAtQ/JpoIRKgFOQzCFuAVcb+0boBh8ptPtBIzTWqG4vDZTUV6"
            + "REw8b6UxR81nD0OkLtbm3cLwqH4PH1mBOt66oTLmmAmcxCrEHPUQMfvPllUP7F1jT8t0JzXzOmuZMEe7+WAId33v0oy9qTna"
            + "wWrbC3GUuubCCdZnAOJ8G4+JCZHB7lGvCYqV7dmGKvLG/XIvPRiff0pqmJ5uSOBpMpeA6XorWlzby1jzi38sBZ+mv5jIWSAO"
            + "bKuZdsii6Xgx6MEf2p1q05a9v9pSKj5IL9AfrIX5nKcXqSV1sFQcFccXKXm5kGpNOggmUDCnQVafC7Jq+hup/KtQSIVxDWhV"
            + "kZaih1Ha+Ez7Y2pfqcvwEqUHuOCVt4EqRx40LLXQJ4TuM9HEc63DBaoYh7SWDF/i0DAAxyKA49Ty1VVyWWE/6kpd97JEFpY1"
            + "czN37utl70HC4MwECZCg4+xljeHKp3W0kpjdiM1IDPmwRb2fmI1aUEdlaG/DCHhMvLyPFkhpCPUDxSWckD9UgHydkCZ3Vsoc"
            + "if7I0TwbxCBkyGEJHjYhzZSzA9m8MDfG/5jie8QCz0h4XN34G3seIa8qG+MsGjUzj/+sQT1BgUATdfxEnlflfUw6YaQXzyga"
            + "kMJWqWID0b13VHBqls694IYvLBssMpTTgZtFuZAf98q05swpElaMLdFoY/FvORbpJFXNPdcxokbunKJzjHVcxUgS1xh+6gUj"
            + "EVUcB92jykuETPT0xNOxwjOwnIWGuIDW43a6OITKqB4wSPOLN/EWeFfL9E0sj7gsrk4xTe65UDHkV9SvP/CN2+ZLEWhygbjj"
            + "NhmWr089ij2AW2jbtz+XQ8p9PCaBA+GpGHmRvQ8BKg6/koNRaQgHgjsCjIw32ftD/lxk5Voj4+wIoYJqC597eAatoKdJa2di"
            + "kw4XozUiDxt1MP+x/O8uBQgoPUSKSgPj3t6HGvnZFIJN5OGW0iQicbONYa68JclWp8eqptv7U3Sl6CQorF1QHR1SpSXaa+5L"
            + "un1XYuCq0abok2meaUip8sFD/YAad1rKMbHGjC+wtwQ4g3b8X2tisqR5xmGCSPwbVGkT1ZtoEltKz6K5UJ/AzOYYyASvwFsd"
            + "padMvnnHUc67/S9lPjRp7Y3GCWIzEljyT5aOspP4v/jrg0w7wSZMRR9uBOPPEzs0tDZIStI9itZXmHQXuhQ6WJlorSuBb1dj"
            + "Uhk2/h3Lc6E1svHxJp4r8xvNENeSKWUeAo0ITmjTcPeH5VMEpEPFMHRMXuH2qNhVlchC2Pw9Lo2PCiB203r7B7rYB+8pOj2B"
            + "kK8ME5ZytjwOV5Y+UZHbsC3fMTkhKbsXCiNr5NxpJ8QgmP00ynpmIFjSNn8rp9Hebza08jsgXQI="
    )

    static func hmacKey(for host: RPHostType) -> [UInt8] {
        host == .ps5 ? hmacKeyPs5 : hmacKeyPs4
    }

    static func regKey0(for host: RPHostType) -> [UInt8] {
        host == .ps5 ? regKey0Ps5 : regKey0Ps4
    }

    static func regKey1(for host: RPHostType) -> [UInt8] {
        host == .ps5 ? regKey1Ps5 : regKey1Ps4
    }

    static func sessionKey0(for host: RPHostType) -> [UInt8] {
        host == .ps5 ? sessionKey0Ps5 : sessionKey0Ps4
    }

    static func sessionKey1(for host: RPHostType) -> [UInt8] {
        host == .ps5 ? sessionKey1Ps5 : sessionKey1Ps4
    }

    private static func decode(_ b64: String) -> [UInt8] {
        guard let data = Data(base64Encoded: b64) else {
            preconditionFailure("RPKeys: invalid embedded key table")
        }
        return [UInt8](data)
    }
}
