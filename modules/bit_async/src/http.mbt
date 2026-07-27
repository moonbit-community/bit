///| Asynchronous HTTP transport used by repository operations.

///|
pub(open) trait AsyncHttpClient {
  async fn get(Self, String, Map[String, String]) -> (
    @types.HttpResponse,
    Bytes,
  ) raise @object.GitError
  async fn post(Self, String, Bytes, Map[String, String]) -> (
    @types.HttpResponse,
    Bytes,
  ) raise @object.GitError
}
