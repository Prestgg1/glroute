pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int, total_tokens: Int, requests: Int)
}

pub fn zero() -> Usage {
  Usage(0, 0, 0, 0)
}

pub type RunResult(output) {
  RunResult(output: output, usage: Usage, raw_response: String)
}
