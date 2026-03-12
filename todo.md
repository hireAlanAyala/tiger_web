questions
- would SSE connections count towards the connection slots?
- put nginx in front of server?

remaining patterns (transport-level, not state machine-level):
- rate limiting — a commit loop concern or connection-level
- file uploads/binary payloads — HTTP parser concern
- webhooks/async notifications — would stress the IO layer, not the state machine
- full-text search — a storage concern (SQLite FTS)

Implement image processing, but keep images outside of the state machien


❯ there will be domain logic such as diff pixels between images, or scan all colors in an image. they can usually be done on a 150x150 resized of the original. would that fit in our systm?   
                                                                                                                                                                                             
● 150×150 pixels × 3 bytes (RGB) = 67,500 bytes. That's larger than body_max (4,096) but smaller than response_body_max (65,536) — and it wouldn't fit in the current incoming message         
  pipeline.                                                                                                                                                                                  
                                                                                                                                                                                               
  But if the worker does the resize, the original image never enters the system at all. The flow would be:
                                                                                                                                                                                               
  1. Client uploads full image to filesystem (uploads/)
  2. Client sends POST /image-jobs with just metadata (job ID, file reference) — small JSON, fits fine
  3. Worker picks up the job, reads from uploads/, resizes to 150×150, does the processing (diff, color scan), posts the result back
  4. Result is small — a color histogram, a diff score, a pixel count — fits in a fixed-size struct

  The resized image is a transient artifact inside the worker. The state machine only ever sees the job metadata and the numeric result. The domain logic (diff, color scan) lives in the
  worker, not the state machine.

  This fits cleanly. The state machine tracks jobs and results. The worker owns the image processing. The filesystem holds the blobs. Each concern stays in its own layer.
