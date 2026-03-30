# This is a monorepo for a liveness and face auth engine.

For now, this provides a flutter SDK and web APIs to perform liveness and face auth checks.
This is going to be a private flutter SDK for now and will later be expanded to support native android and ios.

# Proposed Flutter SDK APIs

final \_liveFaceAuth = await LiveFaceAuth({
"apiKey": "your_api_key",
})

This will check the local secure storage to see if the key has been validated before and if the key is about to expire within a day.
If the key is not valid or about to expire, it calls the server to check if the key is still active and update the validity based on what the server returns.

If the key is valid and not about to expire, it will return true immediately without calling the server.

usage:

\_liveFaceAuth.checkPassiveLiveness(image: base64 encoded image string)

This will use google ml kit to crop the face and then run minifasnet.onnx to return a liveness score. If the score is above a certain threshold, it will return true, otherwise false.

\_liveFaceAuth.checkFaceAuth(referenceImage: base64 encoded image string, useReference:false(default), image: base64 encoded image string, passiveLiveness: true (default), threshold: 80 (default))

This will use google ml kit to crop the face from both the reference and the image. If the useReference is set to true, referenceImage is not required and is ignored and will use the reference from secure storage. If the useReference is set to false, the reference image is used. The sdk then runs minifasnet.onnx to return a liveness score for the image (not the reference). If the score is above a certain threshold, it will then run arcface.onnx to compare the two faces and return a similarity score. If the similarity score is above a certain threshold, it will return true. If the similarity score is below the threshold, it will send it to the server to run a more accurate face comparison and return the result. If the liveness score is below the threshold, it will return false immediately without running the face comparison. If the internet is not available when the model decides to call the server, it will return false with strong: false to indicate that the result is not reliable and should not be used for critical decisions. If the local result is above threshold, internet is not required.

const activeLiveness = ActiveLiveness({
blink: bool,
headNod: bool,(up and down)
headShake: bool (left and right),
})

\_liveFaceAuth.enrollFaceLiveScreen(active: false(default), activeLivenessChecks: activeLiveness (only if active is true), saveReference: false(default))

This will call a enroll face screen where the user will be asked to perform certain actions based on the activeLivenessChecks parameter. If active is false, it will only ask the user to look at the camera and take a picture. If active is true, it will ask the user to perform the specified actions in a random order and then take a picture. The picture will then be used as the reference image for future face auth checks. The picture will be automatically taken 3 seconds after the user performs the last action. The app will also check that the eyes are at a certain distance apart and that the face is not too close or too far from the camera before taking the picture. If the checks fail, it will ask the user to adjust their position and try again. The UI will indicate that the face is not positioned correctly by showing a red border around the camera that will turn green when the position is correct. The app will also check that the user is not wearing a mask or a glass. If the user is wearing a mask or a glass, it will show a message asking the user to remove them and try again. The app will also check that the user is not in a dark environment and will ask the user to move to a well-lit area if the lighting is not sufficient. The app will also check that the user is not in a backlit environment and will ask the user to move to a different location if the lighting is not suitable. The app will also check that the user's face is not too small in the frame and will ask the user to move closer to the camera if the face is too small. The app will also check that the user's face is not too large in the frame and will ask the user to move further away from the camera if the face is too large. The app will have overlay of eyes to guide the user to the right distance from the camera. It can use google ml kit to do this or suggest a better onnx or tflite model to do this but it has to be on device. Once, the image is taken, the face is cropped and is saved and returned along with the vector that is returned by using arcface.onnx. The vector will be used for future face comparisons to improve the accuracy and speed of the face auth checks. If saveReference is true, then the image and vector will be saved in secure storage overriding any previous saved reference.

\_liveFaceAuth.enrollFaceImage(image: base64 encoded image string, saveReference: false(default))

This will take the image, crop the face and return it as the reference image for future face auth checks. The vector that is returned by using arcface.onnx will also be saved and used for future face comparisons to improve the accuracy and speed of the face auth checks. If saveReference is true, then the image and vector will be saved in secure storage overriding any previous saved reference. This method is to be used if the reference image is coming from say the backend or and id card and not from the real person.

\_liveFaceAuth.clearReference()
This will clear the reference image and vector from secure storage. This can be used when the user wants to update their reference image or when the user wants to delete their account.

\_liveFaceAuth.AuthenticateFaceScreen(passive: true(default), active: false(default), activeLivenessChecks: activeLiveness (only if passive is false), faceAuthThreshold: 80 (default))

The liveness part will follow exactly how enrollFaceLiveScreen does. The only difference is that once the liveness passes, and the crop goes through arcface.onxx, the similarity score is compared against the saved reference. If the faceAuthThrehold is met, the authentication is successful and it will return true. If the faceAuthThreshold is not met, it will attempt to call the server to do a more accurate comparison and return the result. If the internet is not available when the model decides to call the server, it will return false with strong: false to indicate that the result is not reliable and should not be used for critical decisions. If the local result is above threshold, internet is not required. If the server was called, the result of the server is final.

# Note: All the sdk calls will need to be logged and the log needs to be maintained in an sqlite db in secure storage for debugging and monitoring purposes. The log will include the timestamp, the userId(this will be returned when using api key), the request id(automatically generated everytime and locally unique for the device), the device id(use a device identifier), the method called, the parameters passed, the result returned, and any errors that occurred and a sync status. Everytime the sdk is used, the sdk will attempt to sync the logs with the server when the internet is available. The server will have an endpoint to receive the logs and store them in a database for monitoring and debugging purposes. The logs will be encrypted before being sent to the server to ensure the privacy and security of the users. The logs will also be used to monitor the usage of the sdk and to identify any potential issues or bugs that need to be addressed. The logs will also be used to monitor the performance of the sdk and to identify any potential bottlenecks or areas for improvement.

# Important notes:

All server calls need to include the api key that was used to initialize the sdk. The server will check if the key is valid and active before processing the request. If the key is not valid or not active, the server will return an error and the sdk will throw that error while saving it in the secure storage that the key is not valid and the sdk needs to be initialized again with a valid key. The sdk will also save the last time the key was validated in secure storage to avoid unnecessary server calls in the future. The sdk will only call the server to validate the key if the key is not valid or if the key is about to expire within a day. This is to ensure that the sdk is always using a valid key while minimizing the number of server calls and to enable legitimate offline usage in low network situations.

# Server:

The server will be a fastapi server that will handle the following endpoints:
POST /validate_key: This endpoint will take the api key and validate it. It will return the validity of the key and the expiry date if the key is valid.

For now, the list of valid keys will be stored against a user in a database and the server will check if the key is valid and active by checking the database. In the future, I might implement a more robust key management system that can handle key generation, revocation, and rotation.

POST /compare_faces: This endpoint will take two face images and compare them using a more accurate but slower model than arcface.onnx. This will be used when the local comparison returns false as there is a lot of false negatives in my experience. The server will also check the validity of the api key before processing the request. If the key is not valid, it will return an error. The server will also log all requests and their results for monitoring and debugging purposes. The server will also have rate limiting to prevent abuse and to ensure fair usage among all users. The server will also have a mechanism to blacklist api keys that are found to be abused or compromised. The server will also have a mechanism to notify the users when their api key is about to expire or has been compromised.
This will also have an option called cropped set to true by default. If the crop is set to true, the server will just run the comparision directly but if it is set to false, the server will first extract the faces from both the images and then run the comparision.
