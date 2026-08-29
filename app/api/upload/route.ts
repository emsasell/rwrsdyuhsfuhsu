import { handleUpload, type HandleUploadBody } from '@vercel/blob/client';
import { NextResponse } from 'next/server';
export const runtime='nodejs';
export async function POST(request:Request){try{const body=await request.json() as HandleUploadBody; const response=await handleUpload({body,request,onBeforeGenerateToken:async()=>({allowedContentTypes:['image/*','video/*','audio/*','application/pdf','application/zip','text/*','application/octet-stream'],maximumSizeInBytes:50*1024*1024,addRandomSuffix:true,tokenPayload:JSON.stringify({app:'emchat'})}),onUploadCompleted:async()=>{}});return NextResponse.json(response)}catch(error){return NextResponse.json({error:error instanceof Error?error.message:'Upload failed'},{status:400})}}
