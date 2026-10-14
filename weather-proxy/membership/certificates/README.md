# Apple App Store JWS 公開信任根憑證

2026-09-16 從 [Apple PKI](https://www.apple.com/certificateauthority/) 的 **Apple Root
Certificates** 區段下載，保留官方 DER 原始檔。這三張是公開 CA 憑證，可以納入版本控制；
此目錄不含 In-App Purchase API 私鑰或測試用自簽憑證。

[Apple App Store Server Library 3.1.0 官方說明](https://github.com/apple/app-store-server-library-node/blob/v3.1.0/README.md#obtaining-apple-root-certificates)
指示將該區段的 roots 傳給 `SignedDataVerifier`。只收錄該區段列出的 Apple Root CA、G2、
G3；不把 WWDR 等 intermediate 當成信任根。App Attest 使用另一條 Apple 信任鏈，仍由
既有 `attestation.js`／`node-app-attest` 處理，不使用這份設定取代它。

| 檔案／官方下載來源 | SHA-256（DER 檔案，亦為憑證指紋） | 有效期（UTC） |
| --- | --- | --- |
| [AppleIncRootCertificate.cer](https://www.apple.com/appleca/AppleIncRootCertificate.cer) | `b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024` | 2006-04-25 21:40:36 ～ 2035-02-09 21:40:36 |
| [AppleRootCA-G2.cer](https://www.apple.com/certificateauthority/AppleRootCA-G2.cer) | `c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050` | 2014-04-30 18:10:09 ～ 2039-04-30 18:10:09 |
| [AppleRootCA-G3.cer](https://www.apple.com/certificateauthority/AppleRootCA-G3.cer) | `63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179` | 2014-04-30 18:19:06 ～ 2039-04-30 18:19:06 |

## 已執行驗證

三張均已通過 OpenSSL DER 解析、自簽簽章驗證（`verify -check_ss_sig`）、當前有效期檢查
及 SHA-256 指紋比對。Subject 與 issuer 相同，且為 CA root。這只確認信任根檔案，
不代表真實 Apple 交易、App Attest 或 Sandbox 端到端流程已通過。

在此目錄可重新核對檔案雜湊：

```sh
shasum -a 256 -c SHA256SUMS
```

以其中一張重新檢查自簽與有效期（其餘兩張同樣操作）：

```sh
certificate_pem=$(mktemp)
openssl x509 -inform DER -in AppleRootCA-G3.cer -out "$certificate_pem"
openssl x509 -in "$certificate_pem" -noout -subject -issuer -dates -fingerprint -sha256
openssl verify -check_ss_sig -CAfile "$certificate_pem" "$certificate_pem"
openssl x509 -in "$certificate_pem" -checkend 0 -noout
rm "$certificate_pem"
```

## 容器設定

目前 `weather-proxy/Dockerfile` 使用 `WORKDIR /app` 及 `COPY . .`；以 `weather-proxy/`
作為 build context 時，這些檔案會位於 `/app/membership/certificates/`。現有
`.dockerignore`／`.gcloudignore` 未排除此目錄。設定值須使用完整的逗號分隔路徑：

```text
MEMBERSHIP_APPLE_ROOT_CERTIFICATES=/app/membership/certificates/AppleIncRootCertificate.cer,/app/membership/certificates/AppleRootCA-G2.cer,/app/membership/certificates/AppleRootCA-G3.cer
```

既有 runtime 會讀取這些 DER bytes 並保持線上憑證撤銷檢查。此變更不修改 runtime、
不注入私鑰、不部署服務，也不啟用會員開關。後續更新憑證時，從上述 Apple 官方來源
重新核對下載內容、自簽、CA 屬性、有效期及雜湊，再一併更新本表與 `SHA256SUMS`。
