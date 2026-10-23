// Tiny signing helper — used ONLY by test.sh so the gateway tests can post
// PayFast IPN/webhook bodies signed exactly the way the server's PayFast
// adapter verifies them, without any real gateway account or network call.
//
// The adapter's documented signature construction (PayFast / APPS hosted
// checkout):  SIGNATURE = MD5 hex of
//   MERCHANT_ID + ":" + MERCHANT_NAME + ":" + TXNAMT + ":" + BASKET_ID
//
// Usage:
//   node test-gateway-stub.js <merchant_id> <merchant_name> <amount> \
//        <basket_id> <response_code> [transaction_id]
//
//   response_code: "00" = success, "failed" = failure, "refunded" = reversal
//
// Prints ONE line: the application/x-www-form-urlencoded webhook body.
import { createHash } from 'node:crypto';

const [merchantId, merchantName, amount, basketId, responseCode, txnId] =
  process.argv.slice(2);
if (!merchantId || !merchantName || !amount || !basketId || !responseCode) {
  console.error('usage: node test-gateway-stub.js <merchant_id> <merchant_name> <amount> <basket_id> <response_code> [transaction_id]');
  process.exit(1);
}
const signature = createHash('md5')
  .update(`${merchantId}:${merchantName}:${amount}:${basketId}`).digest('hex');
const body = new URLSearchParams({
  BASKET_ID: basketId,
  TRANSACTION_ID: txnId || `STUB-${basketId}`,
  TXNAMT: amount,
  RESPONSE_CODE: responseCode,
  SIGNATURE: signature,
});
console.log(body.toString());
